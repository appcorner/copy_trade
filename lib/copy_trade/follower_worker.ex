defmodule CopyTrade.FollowerWorker do
  use GenServer
  require Logger
  alias CopyTrade.TradePairContext

  # --- Client API & Init ---
  def start_link(args) do
    name = {:via, Registry, {CopyTrade.FollowerRegistry, args[:user_id]}}
    GenServer.start_link(__MODULE__, args, name: name)
  end

  def init(args) do
    user_id = args[:user_id]

    # ดึงข้อมูล User เพื่อดูว่าตามใครอยู่
    user = CopyTrade.Accounts.get_user!(user_id)

    Logger.info("👷 Worker started for User [#{user_id}]")

    # Subscribe รอรับ Signal
    Phoenix.PubSub.subscribe(CopyTrade.PubSub, "trade_signals")

    {:ok, %{
      user_id: user_id,
      multiplier: 1.0,
      following_id: user.following_id # เก็บ ID ของ Master ที่เราตาม
    }}
  end

  # --- Handle Signal ---

  # รับ Signal ที่เป็น Map (จาก TCP Server)
  def handle_info(%{action: _} = signal, state) do
    Logger.debug("📩 Signal Received from Master: #{signal.master_id}")
    process_signal(signal, state)
    {:noreply, state}
  end

  # รับ Signal แบบ Tuple (เผื่อไว้ถ้ามีตกค้าง)
  def handle_info({:trade_signal, signal}, state) do
    process_signal(signal, state)
    {:noreply, state}
  end

  # รับการอัปเดต Master (เมื่อ User เปลี่ยนใจไปตามคนอื่น)
  def handle_cast({:update_master, master_id}, state) do
    Logger.info("♻️ Worker [#{state.user_id}] switching to Master ID: #{master_id}")
    {:noreply, %{state | following_id: master_id}}
  end

  # รับ message อื่นๆ ทั่วไป
  def handle_info(_msg, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # ⚔️ CORE LOGIC: กรองสัญญาณและส่งคำสั่ง
  # ------------------------------------------------------------------

  defp process_signal(signal, state) do
    # แปลงเป็น String ทั้งคู่เพื่อความชัวร์ในการเทียบ
    master_id_str = to_string(signal.master_id)
    my_master_str = to_string(state.following_id)

    cond do
      # 1. ถ้าไม่ได้ตามใครเลย
      is_nil(state.following_id) ->
        Logger.debug("🙈 Ignored: Not following anyone")

      # 2. ถ้าสัญญาณนี้ไม่ใช่ของลูกพี่เรา
      master_id_str != my_master_str ->
        # (Uncomment ถ้าอยากเห็น log ถี่ๆ)
        # Logger.debug("🚫 Ignored: Signal from #{master_id_str} (I follow #{my_master_str})")
        :ok

      # 3. ถูกต้อง! เป็นสัญญาณจากลูกพี่ -> ลุยโลด
      true ->
        do_trade_logic(signal, state)
    end
  end

  # ------------------------------------------------------------------
  # 💹 Trade Execution Logic
  # ------------------------------------------------------------------

  # กรณีเปิดออเดอร์ (OPEN_BUY / OPEN_SELL)
  defp do_trade_logic(%{action: "OPEN_" <> type} = signal, state) do
    # 1. กันซ้ำ (ถ้าเคยเปิดคู่นี้ไปแล้ว)
    if TradePairContext.exists?(state.user_id, signal.master_ticket) do
      Logger.warning("⚠️ Duplicate Signal Ignored: #{signal.master_ticket}")
    else
      # 2. บันทึก DB สถานะ PENDING
      db_params = %{
        user_id: state.user_id,
        master_ticket: signal.master_ticket,
        slave_ticket: 0,
        symbol: signal.symbol,
        status: "PENDING",
        open_price: signal.price
      }

      case TradePairContext.create_pair(db_params) do
        {:ok, _pair} ->
          # 3. สร้าง Command ส่งไป TCP
          # Format: CMD_OPEN|BUY|SYMBOL|PRICE|MASTER_TICKET
          command = "CMD_OPEN|#{type}|#{signal.symbol}|#{signal.price}|#{signal.master_ticket}"

          send_tcp_command(state.user_id, command)
          Logger.info("🚀 [#{state.user_id}] Sent OPEN to Slave: #{command}")

        {:error, _} ->
          Logger.error("❌ Failed to save PENDING pair")
      end
    end
  end

  # กรณีปิดออเดอร์ (CLOSE)
  defp do_trade_logic(%{action: "CLOSE"} = signal, state) do
    # 1. หาว่าเราเคยเปิดคู่นี้ไว้ไหม (ต้องมี slave_ticket)
    case TradePairContext.get_slave_ticket(state.user_id, signal.master_ticket) do
      nil ->
        Logger.warning("⚠️ Order Not Found for Close: MasterTicket #{signal.master_ticket}")

      slave_ticket ->
        # 2. สร้าง Command ส่งไป TCP
        # Format: CMD_CLOSE|SYMBOL|SLAVE_TICKET|MASTER_TICKET
        # (ส่ง SlaveTicket ให้ EA ปิดง่ายๆ, แนบ MasterTicket ไว้ update DB ทีหลัง)
        command = "CMD_CLOSE|#{signal.symbol}|#{slave_ticket}|#{signal.master_ticket}"

        send_tcp_command(state.user_id, command)
        Logger.info("📨 [#{state.user_id}] Sent CLOSE to Slave: #{command}")
    end
  end

  # Helper: ส่งข้อมูลเข้า Socket
  defp send_tcp_command(user_id, command) do
    case Registry.lookup(CopyTrade.SocketRegistry, user_id) do
      [{pid, _}] ->
        CopyTrade.SocketHandler.send_command(pid, command)
      [] ->
        Logger.error("❌ Socket not found for user #{user_id}")
    end
  end
end
