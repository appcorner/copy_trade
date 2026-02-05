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

  # 1. รับสัญญาณแบบมหาชน (โหมด PUBSUB)
  def handle_info({:signal, payload}, state) do
    # แปลงข้อมูลเป็น string และส่งออกไปหา EA ผ่าน TCP [cite: 5]
    msg = build_ea_message(payload)
    if msg != "", do: :gen_tcp.send(state.socket, msg <> "\n")
    {:noreply, state}
  end

  # 3. รับคำสั่งปิดทั้งหมด (EMERGENCY CLOSE)
  def handle_info({:direct_signal, %{action: "CLOSE_ALL", reason: reason}}, state) do
    :gen_tcp.send(state.socket, "CMD_CLOSE_ALL|#{reason}\n")
    {:noreply, state}
  end

  # 4. รับคำสั่งปิด Master เมื่อ Slave เปิดไม่สำเร็จ
  def handle_info({:direct_signal, %{action: "CMD_SYNC_CLOSE", master_ticket: master_ticket, reason: reason}}, state) do
    :gen_tcp.send(state.socket, "CMD_SYNC_CLOSE|#{master_ticket}|#{reason}\n")
    {:noreply, state}
  end

  # 2. รับสัญญาณแบบกระซิบ (โหมด 1TO1 จากคู่แท้)
  def handle_info({:direct_signal, payload}, state) do
    # ทำเหมือนกัน แต่ช่องทางนี้จะเร็วกว่าเพราะส่งตรงถึง PID
    msg = build_ea_message(payload)
    if msg != "", do: :gen_tcp.send(state.socket, msg <> "\n")
    {:noreply, state}
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

        # เมื่อ Login สำเร็จ ให้ลงทะเบียน PID ของ Socket นี้ไว้ในชื่อ user_id
        Registry.register(CopyTrade.Registry, "user:#{user_id}", :active)

        %{state | user_id: user_id}
    end
  end

  # 2. SUBSCRIBE:MST-TOKEN
  defp handle_command("SUBSCRIBE:" <> token, state) do
    token = String.trim(token)
    case CopyTrade.Accounts.get_master_by_token(token) do
      nil ->
        :gen_tcp.send(state.socket, "ERROR:MASTER_NOT_FOUND\n")
      master ->
        # set follower mode same as master
        CopyTrade.Accounts.update_user_copy_mode(state.user_id, master.copy_mode)
        # ถ้า Master อยู่ในโหมด 1TO1 ให้ทำการ "จับคู่แท้" ทันที
        if master.copy_mode == "1TO1" do
          partner_id = if is_binary(state.user_id), do: String.to_integer(state.user_id), else: state.user_id
          if master.partner_id == nil || master.partner_id == partner_id do
            CopyTrade.Accounts.bind_partner(master.id, partner_id)
            Logger.info("💑 Exclusive Pair Bound: Master #{master.id} <-> Slave #{partner_id}")
            :gen_tcp.send(state.socket, "SUBSCRIBE_OK\n")
          else
            # ถ้ามีคนอื่นจองอยู่แล้ว ส่ง Error บอก Slave คนใหม่
            :gen_tcp.send(state.socket, "ERROR:MASTER_ALREADY_HAS_PARTNER\n")
          end
        else
          # ถ้าโหมด PUBSUB ให้ยกเลิกความสัมพันธ์คู่แท้ (ถ้ามี)
          CopyTrade.Accounts.unbind_partner(master.id)
          Logger.info("💔 Exclusive Pair Unbound: Master #{master.id}")

          # Link DB
          CopyTrade.Accounts.link_follower_to_master(state.user_id, master.id)
          Logger.info("🔗 [#{state.user_id}] Subscribed to Master ID: #{master.id}")

          # Notify Worker
          update_worker_following(state.user_id, master.id)

          :gen_tcp.send(state.socket, "SUBSCRIBE_OK\n")
        end
    end
    state
  end

  defp handle_command("MASTER_SNAPSHOT:" <> tickets_str, state) do
    actual_tickets =
      tickets_str
      |> String.split(",")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.to_integer/1)
    IO.inspect(actual_tickets, label: ">>> master actual_tickets")

    # กวาดล้างไม้ Master และ Slave ที่ค้างอยู่
    CopyTrade.TradePairContext.reconcile_master_orders(state.user_id, actual_tickets)

    :gen_tcp.send(state.socket, "SNAPSHOT_OK\n")

    # กระจายสัญญาณให้ทุกหน้าจอ Refresh
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})

    state
  end

  defp handle_command("SLAVE_SNAPSHOT:" <> tickets_str, state) do
    # แปลง "123,456" เป็น [123, 456]
    actual_tickets =
      tickets_str
      |> String.split(",")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.to_integer/1)
    IO.inspect(actual_tickets, label: ">>> slave actual_tickets")

    # รันการ Sync และรับรายชื่อไม้ผีกลับมา
    {:ok, zombies} = CopyTrade.TradePairContext.reconcile_slave_orders(state.user_id, actual_tickets)

    # สั่ง EA ปิดไม้ที่ไม่ได้มาจากการ Copy ทันที
    Enum.each(zombies, fn ticket ->
      # ส่งคำสั่งกลับไปหา EA: "CMD_SYNC_CLOSE|ticket|reason"
      msg = "CMD_SYNC_CLOSE|#{ticket}|not in master\n"
      IO.inspect(ticket, label: ">>> closing slave ticket")
      :gen_tcp.send(state.socket, msg)
    end)

    :gen_tcp.send(state.socket, "SNAPSHOT_OK\n")

    # แจ้งหน้าจอให้ Refresh ข้อมูลล่าสุด
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})

    state
  end

  defp handle_command("ALERT_STOP_OUT|" <> reason, state) do
    Logger.error("🚨 STOP OUT ALERT: User #{state.user_id} - #{reason}")

    # 1. เรียกใช้ Kill Switch ส่งหาคู่แท้ทันที
    CopyTrade.TradeSignalRouter.emergency_close_all(state.user_id)

    # 2. แจ้งเตือน Dashboard (Toast Notification)
    CopyTrade.TradePairContext.notify_stop_out(state.user_id, "ACCOUNT")

    state
  end

  # 3. SIGNAL_OPEN|TYPE|SYMBOL|PRICE|VOLUME|SL|TP|TICKET
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

        # Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", payload)
        # 🔥 เปลี่ยนจาก Phoenix.PubSub.broadcast เป็นการใช้ Router
        # เพื่อให้ระบบตัดสินใจเองว่าจะส่งแบบ PUBSUB หรือ 1TO1
        CopyTrade.TradeSignalRouter.dispatch(state.user_id, payload)

      {:error, _changeset} ->
        Logger.error("❌ Failed to save Master Signal")
    end

    state
  end

  defp handle_command("SIGNAL_CLOSE|" <> data, state) do
    [symbol, ticket_str, price_str, profit_str] = String.split(data, "|")

    master_id = state.user_id
    ticket = String.to_integer(ticket_str)
    close_price = String.to_float(price_str)
    profit = String.to_float(profit_str)

    # เรียกใช้ Context เพื่ออัปเดตสถานะทั้ง Master และ Follower ไปพร้อมกัน
    case CopyTrade.TradePairContext.close_master_and_followers(master_id, ticket, close_price, profit) do
      {:ok, _} ->
        payload = %{
          action: "CLOSE",
          symbol: symbol,
          master_ticket: ticket,
          master_id: master_id,
          close_price: close_price,
          profit: profit
        }

        # Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", payload)
        # 🔥 ใช้ Router แทนการ Broadcast ตรงๆ
        CopyTrade.TradeSignalRouter.dispatch(master_id, payload)

      {:error, _} -> Logger.error("❌ Failed to close Master Signal")
    end

    state
  end

  defp handle_command("CMD_SET_MODE|" <> mode, state) do
    mode = String.trim(mode) # "1TO1" หรือ "PUBSUB"

    case CopyTrade.Accounts.update_user_copy_mode(state.user_id, mode) do
      {:ok, _user} ->
        Logger.info("🔄 Master #{state.user_id} switched mode to #{mode}")
        :gen_tcp.send(state.socket, "MODE_UPDATED|#{mode}\n")
      {:error, _} ->
        Logger.error("❌ Failed to update mode for user #{state.user_id}")
        :gen_tcp.send(state.socket, "ERROR:MODE_CHANGE_FAILED\n")
    end

    state
  end

  defp handle_command("CMD_INIT_SYMBOL|" <> data, state) do
    [symbol, c_size, digits] = String.split(data, "|")

    c_size_float = String.to_float(c_size)
    digits_int = String.to_integer(digits)

    # 1. Async Update ลง DB (ไม่ต้องรอผล)
    Task.start(fn ->
      CopyTrade.Accounts.upsert_user_symbol(state.user_id, symbol, c_size_float, digits_int)
    end)

    # 2. Update ลง Cache ทันที
    CopyTrade.Cache.SymbolCache.set_info(state.user_id, symbol, c_size_float, digits_int)

    IO.puts "Cache Updated for User #{state.user_id} - #{symbol}"
    state
  end

  # ตัวอย่างการรับ CMD_PRICE|SYMBOL|BID|ASK
  defp handle_command("CMD_PRICE|" <> data, state) do
    # IO.inspect(data, label: ">>> RECEIVED PRICE FROM EA")
    [symbol, bid_str, ask_str] = String.split(data, "|")

    # IO.inspect(state, label: ">>> state in CMD_PRICE")
    master_id = if is_binary(state.user_id), do: String.to_integer(state.user_id), else: state.user_id

    bid = String.to_float(bid_str)
    ask = String.to_float(ask_str)

    payload = %{
      master_id: master_id,
      symbol: symbol,
      bid: bid,
      ask: ask
    }

    # 1. บันทึกลง ETS (ทับของเก่าทันที)
    :ets.insert(:market_prices, {{master_id, symbol}, %{bid: bid, ask: ask}})

    # Logger.info("Master Prices #{symbol}:#{inspect(%{bid: bid, ask: ask})}")

    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "market_prices", %{
      event: "price_update",
      payload: payload
    })

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

    # แจ้งหน้าจอให้ Refresh ข้อมูลล่าสุด
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})

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

    # แจ้งหน้าจอให้ Refresh ข้อมูลล่าสุด
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})

    state
  end
  # 5.1 SLAVE ACK CLOSE SO - EA ตอบกลับว่าปิดแล้วจาก STOP OUT
  defp handle_command("ACK_CLOSE_SO|" <> data, state) do
    [slave_ticket_str, price_str, profit_str] = String.split(data, "|")

    slave_ticket = String.to_integer(slave_ticket_str)
    price = String.to_float(price_str)
    profit = String.to_float(profit_str)

    Logger.info("💰 Closed! Profit: #{profit}")
    CopyTrade.TradePairContext.mark_as_so_closed(state.user_id, slave_ticket, price, profit)

    CopyTrade.TradeSignalRouter.close_master_after_so(state.user_id, slave_ticket)

    # แจ้งหน้าจอให้ Refresh ข้อมูลล่าสุด
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})

    state
  end

  # 6. SLAVE ACK (ACK_OPEN_FAIL|...) - EA ตอบกลับว่าเปิดแล้วล้มเหลว ถ้าmode 1TO1 ให้ปิด Master ด้วย
  defp handle_command("ACK_OPEN_FAIL|" <> data, state) do
    [master_ticket, reason] = String.split(data, "|")
    master_ticket = String.to_integer(master_ticket)

    Logger.error("❌ Slave failed to open order for Master Ticket #{master_ticket}. Reason: #{reason}")
    CopyTrade.TradeSignalRouter.handle_slave_open_failure(state.user_id, master_ticket, reason)

    # แจ้งหน้าจอให้ Refresh ข้อมูลล่าสุด
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})

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

  defp build_ea_message(%{action: action} = p) when action in ["OPEN_BUY", "OPEN_SELL"] do
    # ส่ง Format: CMD_OPEN|TYPE|SYMBOL|PRICE|VOLUME|SL|TP|MASTER_TICKET [cite: 77, 81]
    type = if action == "OPEN_BUY", do: "BUY", else: "SELL"
    "CMD_OPEN|#{type}|#{p.symbol}|#{p.price}|#{p.volume}|#{p.sl}|#{p.tp}|#{p.master_ticket}"
  end

  defp build_ea_message(%{action: "CLOSE"} = p) do
    "CMD_CLOSE|#{p.symbol}|#{p.slave_ticket}|#{p.master_ticket}"
  end

  defp build_ea_message(_), do: ""
end
