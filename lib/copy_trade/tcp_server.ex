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

  alias CopyTrade.TradePairContext
  #TCP -> Save DB (MasterTrade) -> Broadcast -> Worker -> Save DB (TradePair)

  # --- Init & Info ---
  def init(socket) do
    :inet.setopts(socket, [active: true])
    {:ok, %{socket: socket, user_id: nil}}
  end

  def handle_info({:tcp, _socket, data}, state) do
    data = String.trim(data)
    state = handle_command(data, state)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    if state.user_id do
      Logger.warning("🔌 Offline: #{state.user_id}")
      broadcast_status(state.user_id, :offline)
    end
    {:stop, :normal, state}
  end

  # --- Handle Send Command ---

  # API ให้คนอื่นเรียกใช้
  def send_command(pid, message) do
    GenServer.cast(pid, {:send, message})
  end

  # ส่งข้อมูลออก Socket จริง
  def handle_cast({:send, message}, state) do
    :gen_tcp.send(state.socket, message <> "\n")
    {:noreply, state}
  end

  # -----------------------------------------------------------
  # 🗣️ Command Handlers
  # -----------------------------------------------------------

  # 1. AUTH:API_KEY
  defp handle_command("AUTH:" <> api_key, state) do
    api_key = String.trim(api_key)

    case CopyTrade.Accounts.get_user_by_api_key(api_key) do
      nil ->
        :gen_tcp.send(state.socket, "AUTH_FAILED\n")
        {:stop, :normal, state}

      user ->
        user_id = to_string(user.id)
        Logger.info("🔐 Auth: #{user.email} (ID: #{user_id})")

        # Register & Start Worker
        Registry.register(CopyTrade.SocketRegistry, user_id, nil)

        if user.role == "follower" do
           start_worker_if_needed(user_id)
        end

        broadcast_status(user_id, :online)
        :gen_tcp.send(state.socket, "AUTH_OK\n")

        %{state | user_id: user_id}
    end
  end

  # 2. SUBSCRIBE:MST-TOKEN
  defp handle_command("SUBSCRIBE:" <> token, state) do
    token = String.trim(token)
    case CopyTrade.Accounts.get_master_by_token(token) do
      nil ->
        :gen_tcp.send(state.socket, "ERROR:INVALID_TOKEN\n")
      master ->
        # Link DB
        CopyTrade.Accounts.link_follower_to_master(state.user_id, master.id)
        Logger.info("🔗 [#{state.user_id}] Subscribed to Master ID: #{master.id}")

        # Notify Worker
        update_worker_following(state.user_id, master.id)

        :gen_tcp.send(state.socket, "SUBSCRIBE_OK\n")
    end
    state
  end

  # # 3. MASTER SIGNALS (SIGNAL_OPEN|...)
  # defp handle_command("SIGNAL_OPEN|" <> data, state) do
  #   [type, symbol, price_str, vol_str, sl_str, tp_str, ticket_str] = String.split(data, "|")

  #   payload = %{
  #     action: "OPEN_#{type}",
  #     symbol: symbol,
  #     price: String.to_float(price_str),
  #     volume: String.to_float(vol_str), # ✅ ส่งต่อ volume
  #     sl: String.to_float(sl_str),      # ✅ ส่งต่อ SL
  #     tp: String.to_float(tp_str),      # ✅ ส่งต่อ TP
  #     master_ticket: String.to_integer(ticket_str),
  #     master_id: state.user_id # 🔥 ระบุคนส่ง (Master)
  #   }

  #   Logger.info("📡 Signal: #{payload.action} #{symbol} Lot:#{payload.volume}")
  #   Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", payload)
  #   state
  # end
  defp handle_command("SIGNAL_OPEN|" <> data, state) do
    [type, symbol, price_str, vol_str, sl_str, tp_str, ticket_str] = String.split(data, "|")

    # 1. เตรียมข้อมูล
    params = %{
      master_id: state.user_id,
      ticket: String.to_integer(ticket_str),
      symbol: symbol,
      type: type, # "BUY" / "SELL"
      price: String.to_float(price_str),
      volume: String.to_float(vol_str),
      sl: String.to_float(sl_str),
      tp: String.to_float(tp_str),
      status: "OPEN"
    }

    # 2. 🔥 บันทึกลง Table "master_trades" ก่อนเลย
    case TradePairContext.create_master_trade(params) do
      {:ok, master_trade} ->
        # 3. ถ้าบันทึกสำเร็จ -> ค่อย Broadcast บอกทุกคน
        # แนบ id ของ master_trade ไปด้วย!
        payload = Map.merge(params, %{
          action: "OPEN_#{type}",
          master_ticket: params.ticket, # (คงไว้เพื่อให้ Worker โค้ดเก่าไม่งง)
          master_trade_id: master_trade.id # 🔥 ID สำคัญที่ต้องส่งไป
        })

        Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", payload)

      {:error, _changeset} ->
        Logger.error("❌ Failed to save Master Signal")
    end

    state
  end

  defp handle_command("SIGNAL_CLOSE|" <> data, state) do
    [symbol, ticket_str] = String.split(data, "|")

    payload = %{
      action: "CLOSE",
      symbol: symbol,
      master_ticket: String.to_integer(ticket_str),
      master_id: state.user_id
    }

    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", payload)
    state
  end

  defp handle_command("CHECK_STATUS", state) do
    user = CopyTrade.Accounts.get_user!(state.user_id)

    status_msg =
      if user.following_id do
        "STATUS_ACTIVE"
      else
        "STATUS_INACTIVE"
      end

    :gen_tcp.send(state.socket, status_msg <> "\n")
    state
  end

  # 4. SLAVE ACK (ACK_OPEN|...) - EA ตอบกลับว่าเปิดแล้ว
  defp handle_command("ACK_OPEN|" <> data, state) do
    [master_ticket, slave_ticket, slave_vol_str, slave_type] = String.split(data, "|")

    slave_volume = String.to_float(slave_vol_str) # ✅ แปลงเป็น float

    Logger.info("✅ Order Opened! Master:#{master_ticket} -> Slave:#{slave_ticket} Lot: #{slave_volume}")

    CopyTrade.TradePairContext.update_slave_ticket(
      state.user_id,
      String.to_integer(master_ticket),
      String.to_integer(slave_ticket),
      slave_volume,
      slave_type
    )
    state
  end

  # 5. SLAVE ACK CLOSE - EA ตอบกลับว่าปิดแล้ว
  defp handle_command("ACK_CLOSE|" <> data, state) do
    [master_ticket_str, price_str, profit_str] = String.split(data, "|")

    master_ticket = String.to_integer(master_ticket_str)
    price = String.to_float(price_str)
    profit = String.to_float(profit_str)

    Logger.info("💰 Closed! Profit: #{profit}")
    CopyTrade.TradePairContext.mark_as_closed(state.user_id, master_ticket, price, profit)
    state
  end

  # Catch-all
  defp handle_command(_, state), do: state

  # --- Helpers ---
  defp start_worker_if_needed(user_id) do
    DynamicSupervisor.start_child(CopyTrade.FollowerSupervisor, {CopyTrade.FollowerWorker, user_id: user_id})
  end

  defp update_worker_following(user_id, master_id) do
    case Registry.lookup(CopyTrade.FollowerRegistry, user_id) do
      [{pid, _}] -> GenServer.cast(pid, {:update_master, master_id})
      [] -> start_worker_if_needed(user_id)
    end
  end

  defp broadcast_status(user_id, status) do
    user = CopyTrade.Accounts.get_user!(user_id)
    info = %{id: user.id, name: user.name, email: user.email}
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "admin_dashboard", {:follower_status, info, status})
  end
end
