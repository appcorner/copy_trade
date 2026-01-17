defmodule CopyTrade.TCPServer do
  use GenServer
  require Logger

  # --- ส่วนของ Server (คนเปิดประตู) ---
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    port = opts[:port] || 5001
    Logger.info("🔌 TCP Server listening on port #{port}")
    # เปิด Port แบบ Passive (รอรับ)
    {:ok, socket} = :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])

    # เริ่ม Loop รับแขก
    Task.start_link(fn -> accept_loop(socket) end)
    {:ok, %{socket: socket}}
  end

  defp accept_loop(socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        Logger.info("🔌 New Connection Accepted")
        # ส่งต่อให้ Handler ดูแล
        {:ok, pid} = GenServer.start_link(CopyTrade.SocketHandler, client)
        :gen_tcp.controlling_process(client, pid)
        accept_loop(socket)

      {:error, reason} ->
        Logger.error("❌ Accept Error: #{inspect(reason)}")
    end
  end
end

defmodule CopyTrade.SocketHandler do
  use GenServer
  require Logger

  # --- ส่วนของ Handler (คนดูแล User) ---
  def init(socket) do
    # ตั้งให้ Socket ส่งข้อมูลเข้ามาเป็น Message
    :inet.setopts(socket, [active: true])
    {:ok, %{socket: socket, user_id: nil}}
  end

  # 1. รับข้อมูลจาก EA (Login หรือ Heartbeat)
  def handle_info({:tcp, _socket, data}, state) do
    data = String.trim(data) # ตัด \n ออก
    state = handle_command(data, state)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    if state.user_id do
      Logger.warning("🔌 Socket Closed for user: #{state.user_id}")
      # 🔥 ประกาศข่าว: User Offline
      broadcast_status(state.user_id, :offline)
    end
    {:stop, :normal, state}
  end

  # ฟังก์ชันส่งคำสั่งไปหา EA
  def send_command(pid, message) do
    GenServer.cast(pid, {:send, message})
  end

  def handle_cast({:send, message}, state) do
    # ส่งข้อมูลกลับไปหา EA (เติม \n ปิดท้ายเสมอ)
    :gen_tcp.send(state.socket, message <> "\n")
    {:noreply, state}
  end

  # --- Logic การคุยกับ EA ---

  # # กรณี EA ส่งมาว่า: "AUTH:User123"
  # defp handle_command("AUTH:" <> user_id, state) do
  #   Logger.info("🔐 Client Authenticated: #{user_id}")

  #   # ลงทะเบียน Socket นี้เข้ากับ User ID
  #   Registry.register(CopyTrade.SocketRegistry, user_id, nil)

  #   # 🔥 2. เพิ่มส่วนนี้: ปลุก Worker ขึ้นมาทำงานอัตโนมัติ!
  #   start_worker_if_needed(user_id)

  #   # 🔥 ประกาศข่าว: User Online
  #   broadcast_status(user_id, :online)

  #   # ตอบกลับว่า OK
  #   :gen_tcp.send(state.socket, "AUTH_OK\n")

  #   %{state | user_id: user_id}
  # end

  # -----------------------------------------------------------
  # 🔐 Auth ด้วย API Key
  # -----------------------------------------------------------
  defp handle_command("AUTH:" <> api_key, state) do
    api_key = String.trim(api_key)

    # 1. ค้นหา User จาก API Key ใน DB
    # (เราต้องไปเขียนฟังก์ชัน get_user_by_api_key ใน Accounts context ก่อน)
    case CopyTrade.Accounts.get_user_by_api_key(api_key) do
      nil ->
        Logger.warning("❌ Auth Failed: Invalid API Key")
        :gen_tcp.send(state.socket, "AUTH_FAILED\n")
        # ตัดการเชื่อมต่อทันที
        {:stop, :normal, state}

      user ->
        user_id = to_string(user.id) # แปลง ID เป็น String เพื่อใช้ใน Registry
        Logger.info("🔐 Auth Success: #{user.email} (#{user.role})")

        # 2. ลงทะเบียน Socket ด้วย User ID (เหมือนเดิม เพื่อให้ Worker หาเจอ)
        Registry.register(CopyTrade.SocketRegistry, user_id, nil)

        # 3. ถ้าเป็น Follower ให้ปลุก Worker
        if user.role == "follower" do
          start_worker_if_needed(user_id)
        end

        # 4. แจ้ง Dashboard
        broadcast_status(user_id, :online)

        :gen_tcp.send(state.socket, "AUTH_OK\n")
        %{state | user_id: user_id} # เก็บ User ID ไว้ใน State
    end
  end

  # กรณีได้รับแจ้งว่าเปิดออเดอร์สำเร็จ
  # Format: ACK_OPEN|MASTER_TICKET|SLAVE_TICKET
  defp handle_command("ACK_OPEN|" <> data, state) do
    [master_ticket_str, slave_ticket_str] = String.split(data, "|")

    master_ticket = String.to_integer(master_ticket_str)
    slave_ticket = String.to_integer(slave_ticket_str)

    Logger.info("✅ [#{state.user_id}] EA Confirm Open! Master: #{master_ticket} -> Slave: #{slave_ticket}")

    # 🔥 เรียก Context ไปอัปเดต DB
    CopyTrade.TradePairContext.update_slave_ticket(state.user_id, master_ticket, slave_ticket)

    state
  end

  # 3. กรณี EA ตอบกลับการปิด (ACK_CLOSE)
  defp handle_command("ACK_CLOSE|" <> data, state) do
    [master_ticket_str, price_str, profit_str] = String.split(data, "|")

    master_ticket = String.to_integer(master_ticket_str)
    price = String.to_float(price_str)
    profit = String.to_float(profit_str)

    Logger.info("💰 [#{state.user_id}] Close Confirmed! Profit: #{profit}")

    # 🔥 เรียก Context ไปอัปเดต DB
    CopyTrade.TradePairContext.mark_as_closed(state.user_id, master_ticket, price, profit)

    state
  end

  # กรณีอื่นๆ (เช่น Ping)
  defp handle_command(cmd, state) do
    Logger.debug("📩 Recv from #{state.user_id}: #{cmd}")
    state
  end

  # ฟังก์ชันช่วยปลุก Worker
  defp start_worker_if_needed(user_id) do
    # ลองสั่ง Start Worker ผ่าน Supervisor
    case DynamicSupervisor.start_child(CopyTrade.FollowerSupervisor, {CopyTrade.FollowerWorker, user_id: user_id}) do
      {:ok, _pid} ->
        Logger.info("🧠 Auto-started Worker for #{user_id}")

      {:error, {:already_started, _pid}} ->
        Logger.info("🧠 Worker #{user_id} is already running")

      {:error, reason} ->
        Logger.error("❌ Failed to auto-start worker: #{inspect(reason)}")
    end
  end

  defp broadcast_status(user_id, status) do
    # ดึงข้อมูล User ล่าสุด
    user = CopyTrade.Accounts.get_user!(user_id)

    # ส่งไปทั้งก้อนเลย (Map)
    user_info = %{id: user.id, name: user.name, email: user.email}

    # ส่งไปที่ topic "admin_dashboard"
    Phoenix.PubSub.broadcast(
      CopyTrade.PubSub,
      "admin_dashboard",
      {:follower_status, user_info, status}
    )
  end
end
