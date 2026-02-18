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
  alias CopyTrade.Accounts

  #TCP -> Save DB (MasterTrade) -> Broadcast -> Worker -> Save DB (TradePair)

  # --- Init & Info ---
  def init(socket) do
    :inet.setopts(socket, [active: true])
    {:ok, %{socket: socket, account_id: nil}}
  end

  def handle_info({:tcp, _socket, data}, state) do
    data = String.trim(data)
    state = handle_command(data, state)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    if state.account_id do
      Logger.warning("🔌 Offline: Account #{state.account_id}")
      broadcast_status(state.account_id, :offline)
    end
    {:stop, :normal, state}
  end

  # 1. รับสัญญาณแบบมหาชน (โหมด PUBSUB)
  def handle_info({:signal, payload}, state) do
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
    msg = build_ea_message(payload)
    if msg != "", do: :gen_tcp.send(state.socket, msg <> "\n")
    {:noreply, state}
  end

  # --- Handle Send Command ---

  def send_command(pid, message) do
    GenServer.cast(pid, {:send, message})
  end

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

    case Accounts.get_account_by_api_key(api_key) do
      nil ->
        :gen_tcp.send(state.socket, "AUTH_FAILED\n")
        {:stop, :normal, state}

      account ->
        account_id = account.id
        Logger.info("🔐 Auth: #{account.name} (Role: #{account.role})")

        # Register & Start Worker (ใช้ account_id แทน user_id)
        Registry.register(CopyTrade.SocketRegistry, to_string(account_id), nil)

        if account.role == "follower" do
           start_worker_if_needed(account_id)
        end

        broadcast_status(account_id, :online)
        :gen_tcp.send(state.socket, "AUTH_OK\n")

        # ลงทะเบียน PID ด้วย key "account:{id}"
        Registry.register(CopyTrade.Registry, "account:#{account_id}", :active)

        %{state | account_id: account_id}
    end
  end

  # 2. SUBSCRIBE:MST-TOKEN
  defp handle_command("SUBSCRIBE:" <> token, state) do
    token = String.trim(token)
    case Accounts.get_master_account_by_token(token) do
      nil ->
        :gen_tcp.send(state.socket, "ERROR:MASTER_NOT_FOUND\n")
      master ->
        # set follower mode same as master
        Accounts.update_account_copy_mode(state.account_id, master.copy_mode)
        
        if master.copy_mode == "1TO1" do
          partner_id = state.account_id
          if master.partner_id == nil || master.partner_id == partner_id do
            Accounts.bind_partner(master.id, partner_id)
            Logger.info("💑 Exclusive Pair Bound: Master #{master.id} <-> Slave #{partner_id}")
            :gen_tcp.send(state.socket, "SUBSCRIBE_OK\n")
          else
            :gen_tcp.send(state.socket, "ERROR:MASTER_ALREADY_HAS_PARTNER\n")
          end
        else
          Accounts.unbind_partner(master.id)
          Logger.info("💔 Exclusive Pair Unbound: Master #{master.id}")

          Accounts.link_follower_to_master(state.account_id, master.id)
          Logger.info("🔗 [#{state.account_id}] Subscribed to Master ID: #{master.id}")

          update_worker_following(state.account_id, master.id)

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

    CopyTrade.TradePairContext.reconcile_master_orders(state.account_id, actual_tickets)
    :gen_tcp.send(state.socket, "SNAPSHOT_OK\n")
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})
    state
  end

  defp handle_command("SLAVE_SNAPSHOT:" <> tickets_str, state) do
    actual_tickets =
      tickets_str
      |> String.split(",")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.to_integer/1)

    {:ok, zombies} = CopyTrade.TradePairContext.reconcile_slave_orders(state.account_id, actual_tickets)

    Enum.each(zombies, fn ticket ->
      msg = "CMD_SYNC_CLOSE|#{ticket}|not in master\n"
      :gen_tcp.send(state.socket, msg)
    end)

    :gen_tcp.send(state.socket, "SNAPSHOT_OK\n")
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})
    state
  end

  defp handle_command("ALERT_STOP_OUT|" <> reason, state) do
    Logger.error("🚨 STOP OUT ALERT: Account #{state.account_id} - #{reason}")
    CopyTrade.TradeSignalRouter.emergency_close_all(state.account_id)
    CopyTrade.TradePairContext.notify_stop_out(state.account_id, "ACCOUNT")
    state
  end

  # 3. SIGNAL_OPEN|TYPE|SYMBOL|PRICE|VOLUME|SL|TP|TICKET
  defp handle_command("SIGNAL_OPEN|" <> data, state) do
    [type, symbol, price_str, vol_str, sl_str, tp_str, ticket_str] = String.split(data, "|")

    params = %{
      master_id: state.account_id,
      ticket: String.to_integer(ticket_str),
      symbol: symbol,
      type: type,
      price: String.to_float(price_str),
      volume: String.to_float(vol_str),
      sl: String.to_float(sl_str),
      tp: String.to_float(tp_str),
      status: "OPEN"
    }

    case TradePairContext.create_master_trade(params) do
      {:ok, master_trade} ->
        payload = Map.merge(params, %{
          action: "OPEN_#{type}",
          master_ticket: params.ticket,
          master_trade_id: master_trade.id
        })
        CopyTrade.TradeSignalRouter.dispatch(state.account_id, payload)

      {:error, _changeset} ->
        Logger.error("❌ Failed to save Master Signal")
    end

    state
  end

  defp handle_command("SIGNAL_CLOSE|" <> data, state) do
    [symbol, ticket_str, price_str, profit_str] = String.split(data, "|")

    master_id = state.account_id
    ticket = String.to_integer(ticket_str)
    close_price = String.to_float(price_str)
    profit = String.to_float(profit_str)

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
        CopyTrade.TradeSignalRouter.dispatch(master_id, payload)

      {:error, _} -> Logger.error("❌ Failed to close Master Signal")
    end

    state
  end

  defp handle_command("CMD_SET_MODE|" <> mode, state) do
    mode = String.trim(mode)

    case Accounts.update_account_copy_mode(state.account_id, mode) do
      {:ok, _} ->
        Logger.info("🔄 Master #{state.account_id} switched mode to #{mode}")
        :gen_tcp.send(state.socket, "MODE_UPDATED|#{mode}\n")
      {:error, _} ->
        :gen_tcp.send(state.socket, "ERROR:MODE_CHANGE_FAILED\n")
    end

    state
  end

  defp handle_command("CMD_INIT_SYMBOL|" <> data, state) do
    [symbol, c_size, digits] = String.split(data, "|")
    c_size_float = String.to_float(c_size)
    digits_int = String.to_integer(digits)

    # TODO: Refactor upsert_user_symbol to use account_id
    Task.start(fn ->
      Accounts.upsert_user_symbol(state.account_id, symbol, c_size_float, digits_int)
    end)

    CopyTrade.Cache.SymbolCache.set_info(state.account_id, symbol, c_size_float, digits_int)
    state
  end

  defp handle_command("CMD_PRICE|" <> data, state) do
    [symbol, bid_str, ask_str] = String.split(data, "|")

    master_id = state.account_id
    bid = String.to_float(bid_str)
    ask = String.to_float(ask_str)

    payload = %{
      master_id: master_id,
      symbol: symbol,
      bid: bid,
      ask: ask
    }

    :ets.insert(:market_prices, {{master_id, symbol}, %{bid: bid, ask: ask}})

    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "market_prices", %{
      event: "price_update",
      payload: payload
    })

    state
  end

  defp handle_command("CHECK_STATUS", state) do
    account = Accounts.get_trading_account!(state.account_id)

    status_msg =
      if account.following_id do
        "STATUS_ACTIVE"
      else
        "STATUS_INACTIVE"
      end

    :gen_tcp.send(state.socket, status_msg <> "\n")
    state
  end

  defp handle_command("ACK_OPEN|" <> data, state) do
    [master_ticket, slave_ticket, slave_vol_str, slave_type] = String.split(data, "|")
    slave_volume = String.to_float(slave_vol_str)

    Logger.info("✅ Order Opened! Master:#{master_ticket} -> Slave:#{slave_ticket}")

    CopyTrade.TradePairContext.update_slave_ticket(
      state.account_id,
      String.to_integer(master_ticket),
      String.to_integer(slave_ticket),
      slave_volume,
      slave_type
    )
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})
    state
  end

  defp handle_command("ACK_CLOSE|" <> data, state) do
    [master_ticket_str, price_str, profit_str] = String.split(data, "|")
    master_ticket = String.to_integer(master_ticket_str)
    price = String.to_float(price_str)
    profit = String.to_float(profit_str)

    Logger.info("💰 Closed! Profit: #{profit}")
    CopyTrade.TradePairContext.mark_as_closed(state.account_id, master_ticket, price, profit)
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})
    state
  end

  defp handle_command("ACK_CLOSE_SO|" <> data, state) do
    [slave_ticket_str, price_str, profit_str] = String.split(data, "|")
    slave_ticket = String.to_integer(slave_ticket_str)

    CopyTrade.TradePairContext.mark_as_so_closed(
      state.account_id, slave_ticket, String.to_float(price_str), String.to_float(profit_str)
    )
    CopyTrade.TradeSignalRouter.close_master_after_so(state.account_id, slave_ticket)
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})
    state
  end

  defp handle_command("ACK_OPEN_FAIL|" <> data, state) do
    [master_ticket, reason] = String.split(data, "|")
    Logger.error("❌ Slave failed to open: #{reason}")
    CopyTrade.TradeSignalRouter.handle_slave_open_failure(state.account_id, String.to_integer(master_ticket), reason)
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", %{event: "refresh"})
    state
  end

  defp handle_command(_, state), do: state

  # --- Helpers ---
  defp start_worker_if_needed(account_id) do
    # Pass account_id instead of user_id. Ensure Worker handles it.
    DynamicSupervisor.start_child(CopyTrade.FollowerSupervisor, {CopyTrade.FollowerWorker, user_id: account_id})
  end

  defp update_worker_following(account_id, master_id) do
    # Registry now uses account ID string
    case Registry.lookup(CopyTrade.FollowerRegistry, to_string(account_id)) do
      [{pid, _}] -> GenServer.cast(pid, {:update_master, master_id})
      [] -> start_worker_if_needed(account_id)
    end
  end

  defp broadcast_status(account_id, status) do
    account = Accounts.get_trading_account!(account_id)
    info = %{id: account.id, name: account.name, role: account.role}
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "admin_dashboard", {:follower_status, info, status})
  end

  defp build_ea_message(%{action: action} = p) when action in ["OPEN_BUY", "OPEN_SELL"] do
    type = if action == "OPEN_BUY", do: "BUY", else: "SELL"
    "CMD_OPEN|#{type}|#{p.symbol}|#{p.price}|#{p.volume}|#{p.sl}|#{p.tp}|#{p.master_ticket}"
  end

  defp build_ea_message(%{action: "CLOSE"} = p) do
    "CMD_CLOSE|#{p.symbol}|#{p.slave_ticket}|#{p.master_ticket}"
  end

  defp build_ea_message(_), do: ""
end
