defmodule CopyTrade.FollowerWorker do
  use GenServer
  require Logger
  alias CopyTrade.TradePairContext # 🔥 อย่าลืมเติม alias นี้

  # --- Client API & Init (เหมือนเดิม) ---
  def start_link(args) do
    name = {:via, Registry, {CopyTrade.FollowerRegistry, args[:user_id]}}
    GenServer.start_link(__MODULE__, args, name: name)
  end

  def init(args) do
    # 🔥 แก้ตรงนี้: แปลง Keyword List ให้เป็น Map ก่อน
    state = Map.new(args)

    Logger.info("✅ Follower #{state[:user_id]} Online!")
    Phoenix.PubSub.subscribe(CopyTrade.PubSub, "gold_signals")

    # เพิ่ม multiplier ไว้คูณ Lot (Default 1.0)
    {:ok, Map.put(state, :multiplier, 1.0)}
  end

  # --- Handle Signal ---
  def handle_info({:trade_signal, signal}, state) do
    # Log รับทราบ (Debug)
    Logger.debug("🔔 [#{state[:user_id]}] Signal Received: #{signal.action}")

    Task.start(fn ->
      process_signal(signal, state)
    end)
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # 🟢 LOGIC 1: การเปิดออเดอร์ (OPEN_BUY, OPEN_SELL)
  # ------------------------------------------------------------------
  defp process_signal(%{action: "OPEN_" <> type} = signal, state) do
    # 1. กันซ้ำ
    if TradePairContext.exists?(state.user_id, signal.master_ticket) do
      Logger.warning("⚠️ [#{state.user_id}] Duplicate Signal Ignored: #{signal.master_ticket}")
    else
      # 2. คำนวณ Lot Size
      lot = Float.round(signal.volume * state.multiplier, 2)
      lot = max(lot, 0.01)

      # -------------------------------------------------------
      # 🔥 จุดเปลี่ยนสำคัญ: บันทึก DB ก่อนส่ง TCP (Async Pattern)
      # -------------------------------------------------------

      # 3. สร้างข้อมูลเพื่อเตรียมบันทึก (PENDING)
      # slave_ticket ใส่ 0 ไปก่อน เพราะเรายังไม่รู้
      db_params = %{
        user_id: state.user_id,
        master_ticket: signal.master_ticket,
        slave_ticket: 0,         # <--- Placeholder
        symbol: signal.symbol,
        status: "PENDING",       # <--- สถานะรอการตอบกลับ
        open_price: signal.price
      }

      # 4. บันทึกลง Database ทันที
      case TradePairContext.create_pair(db_params) do
        {:ok, _pair} ->
          Logger.info("💾 [#{state.user_id}] Saved PENDING pair for Master: #{signal.master_ticket}")

          # 5. เตรียม Payload ส่ง TCP
          # ต้องแนบ master_ticket ไปด้วย เพื่อให้ EA ส่งกลับมาถูกคู่
          payload = %{
            action: type,     # "BUY" หรือ "SELL"
            user_id: state.user_id,
            symbol: signal.symbol,
            volume: lot,
            magic: 123456,
            master_ticket: signal.master_ticket # 🔥 สำคัญมาก ต้องส่งตัวนี้ไปด้วย
          }

          # 6. ยิง TCP (Fire-and-forget)
          execute_tcp(payload)

        {:error, changeset} ->
          Logger.error("❌ DB Insert Failed: #{inspect(changeset.errors)}")
      end
    end
  end

  # ------------------------------------------------------------------
  # 🔴 LOGIC 2: การปิดออเดอร์ (CLOSE)
  # ------------------------------------------------------------------
  defp process_signal(%{action: "CLOSE"} = signal, state) do
    # 1. ค้นหา Slave Ticket
    case TradePairContext.get_slave_ticket(state.user_id, signal.master_ticket) do
      nil ->
        Logger.error("⚠️ [#{state.user_id}] Order Not Found for Master Ticket: #{signal.master_ticket}")

      slave_ticket ->
        # 2. เตรียม Payload
        # 🔥 เพิ่ม master_ticket ไปด้วย (เพื่อใช้เป็น Reference ตอน EA ส่งกลับ)
        payload = %{
          action: "CLOSE",
          user_id: state.user_id,
          ticket: slave_ticket,
          symbol: signal.symbol,
          master_ticket: signal.master_ticket
        }

        # 3. ยิง TCP (Fire-and-forget)
        execute_tcp(payload)

        # ไม่ต้องรอ response และไม่ต้อง update DB ตรงนี้
        Logger.info("📨 [#{state.user_id}] Sent CLOSE command for Ticket: #{slave_ticket}")
    end
  end

  # แก้ Helper execute_tcp
  defp execute_tcp(%{action: "CLOSE"} = p) do
    # Format: CLOSE|SYMBOL|SLAVE_TICKET|MASTER_TICKET
    command = "CLOSE|#{p.symbol}|#{p.ticket}|#{p.master_ticket}"

    case Registry.lookup(CopyTrade.SocketRegistry, p.user_id) do
      [{pid, _}] -> CopyTrade.SocketHandler.send_command(pid, command)
      [] -> Logger.error("❌ Socket not found")
    end
    {:ok, %{}}
  end

  # Helper: จัดรูปแบบคำสั่ง TCP
  defp execute_tcp(payload) do
    user_id = payload[:user_id]

    case Registry.lookup(CopyTrade.SocketRegistry, user_id) do
      [{pid, _}] ->
        # สร้าง String ตาม Format ใหม่:
        # OPEN|BUY|SYMBOL|VOL|MAGIC|MASTER_TICKET

        command = "OPEN|#{payload.action}|#{payload.symbol}|#{payload.volume}|#{payload.magic}|#{payload.master_ticket}"

        CopyTrade.SocketHandler.send_command(pid, command)

        # คืนค่าแบบ Dummy ไปก่อน (ไม่ได้ใช้จริง เพราะเราบันทึก DB ไปแล้ว)
        {:ok, %{}}

      [] ->
        Logger.error("❌ Socket not found for User: #{user_id}")
        {:error, :socket_not_found}
    end
  end
end
