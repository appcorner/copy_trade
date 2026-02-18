# lib/copy_trade/trade_signal_router.ex
defmodule CopyTrade.TradeSignalRouter do
  require Logger
  alias CopyTrade.Accounts
  alias CopyTrade.Accounts.TradingAccount
  # alias Phoenix.PubSub

  @spec dispatch(any(), any()) :: any()
  @doc """
  ฟังก์ชันหลักในการกระจายสัญญาณ
  จะตรวจสอบโหมดของ Master และส่งสัญญาณผ่านช่องทางที่เหมาะสม
  """
  def dispatch(master_id, signal_data) do
    # ดึงข้อมูล Master เพื่อดู copy_mode และ partner_id
    master = Accounts.get_trading_account!(master_id)

    case master.copy_mode do
      "1TO1" ->
        # โหมดคู่แท้: ส่งตรงถึง Partner คนเดียวแบบ Exclusive
        handle_1to1_dispatch(master.partner_id, signal_data)

      "PUBSUB" ->
        # โหมดมหาชน: กระจายผ่าน Phoenix PubSub (Scalable)
        Phoenix.PubSub.broadcast(CopyTrade.PubSub, "trade_signals", signal_data)

      "RECORD" ->
        # โหมดบันทึกอย่างเดียว: บันทึกข้อมูลเทรดลง DB แต่ไม่ส่งสัญญาณไปยัง Follower
        Logger.info("📝 [RECORD] Master #{master_id} - Trade recorded (no signal broadcast): #{inspect(signal_data[:action])}")
        :ok

      _ ->
        IO.puts "Unknown copy mode for Master Account #{master_id}"
    end
  end

  # ฟังก์ชันช่วยส่งสัญญาณแบบ Direct (กระซิบ)
  defp handle_1to1_dispatch(nil, _data) do
    IO.puts "Warning: Master Account is in 1TO1 mode but has no partner assigned."
  end

  defp handle_1to1_dispatch(partner_id, signal_data) do
    # ตรวจสอบ action จาก signal_data
    case signal_data[:action] do
      # กรณีเปิดไม้ (OPEN_BUY หรือ OPEN_SELL)
      action when action in ["OPEN_BUY", "OPEN_SELL"] ->
        handle_open_1to1(partner_id, signal_data)

      # กรณีปิดไม้
      "CLOSE" ->
        handle_close_1to1(partner_id, signal_data)

      _ ->
        # กรณีอื่นๆ เช่น Update SL/TP (ถ้ามี)
        send_to_pid(partner_id, signal_data)
    end
  end

  defp send_to_pid(partner_id, signal_data) do
    case Registry.lookup(CopyTrade.Registry, "account:#{partner_id}") do
      [{pid, _}] ->
        send(pid, {:direct_signal, signal_data})
      [] ->
        IO.puts "Partner (Account #{partner_id}) is currently offline."
    end
  end

  defp handle_open_1to1(partner_id, signal_data) do
    params = %{
      account_id: partner_id, # UPDATED
      master_id: signal_data.master_id, # This is usually master_user_id (now account_id)
      master_trade_id: signal_data.master_trade_id,
      master_ticket: signal_data.master_ticket,
      slave_ticket: 0,
      symbol: signal_data.symbol,
      type: signal_data.type,
      status: "PENDING",
      open_price: signal_data.price,
      volume: signal_data.volume,
      sl: signal_data.sl,
      tp: signal_data.tp
    }

    case CopyTrade.TradePairContext.create_trade_pair(params) do
      {:ok, trade_pair} ->
        # ส่งสัญญาณไปที่ Slave พร้อมแนบ trade_pair_id ไปด้วย
        enriched_data = Map.put(signal_data, :trade_pair_id, trade_pair.id)
        send_to_pid(partner_id, enriched_data)

      {:error, _} -> Logger.error("Could not create trade_pair for 1TO1")
    end
  end

  defp handle_close_1to1(partner_id, signal_data) do
    # 1. ค้นหา trade_pair ที่ยัง OPEN อยู่ของคู่แท้คนนี้ โดยอ้างอิงจาก master_ticket
    case CopyTrade.TradePairContext.get_slave_ticket(partner_id, signal_data.master_ticket) do
      nil ->
        Logger.error("❌ 1TO1: No open trade_pair found for master_ticket #{signal_data.master_ticket}")
        # ส่งสัญญาณไปตามเดิม แต่อาจจะใส่ slave_ticket เป็น 0 (EA จะต้องไปไล่ปิดเองจาก Comment)
        send_to_pid(partner_id, Map.put(signal_data, :slave_ticket, 0))

      slave_ticket ->
        # 2. แนบ slave_ticket ที่เราบันทึกไว้ตอน ACK_OPEN กลับไปใน payload
        enriched_data = Map.put(signal_data, :slave_ticket, slave_ticket)

        # 3. ส่งสัญญาณตรง (กระซิบ)
        send_to_pid(partner_id, enriched_data)
    end
  end

  def emergency_close_all(sender_id) do
    # 1. ดึงข้อมูลผู้ส่ง (ไม่ว่าจะเป็น Master หรือ Slave)
    sender = Accounts.get_trading_account!(sender_id)

    # 2. ตรวจสอบเงื่อนไข: ต้องเป็นโหมด 1TO1 เท่านั้นถึงจะทำ Kill Switch แบบคู่แท้
    if sender.copy_mode == "1TO1" do
      # 3. ค้นหา ID ของคู่แท้ (Partner)
      partner_id = find_partner_id(sender)

      if partner_id do
        # 4. ส่งสัญญาณตรง (Direct) ไปที่ PID ของคู่แท้
        case Registry.lookup(CopyTrade.Registry, "account:#{partner_id}") do
          [{pid, _}] ->
            send(pid, {:direct_signal, %{action: "CLOSE_ALL", reason: "partner stop out"}})
            Logger.warning("🚨 [1TO1] Emergency Close All sent to Partner Account ID: #{partner_id}")
          [] ->
            Logger.error("❌ [1TO1] Partner Account #{partner_id} is offline. Emergency command failed.")
        end
      else
        Logger.info("ℹ️ [1TO1] Account #{sender_id} has no partner assigned yet.")
      end
    else
      # ถ้าเป็นโหมด PUBSUB อาจจะแค่ส่ง Notification หรือทำลอจิกอื่น
      Logger.info("ℹ️ [PUBSUB] Stop Out detected, but 1TO1 Kill Switch is disabled.")
    end
  end

  @doc """
  ส่งคำสั่งปิด master ออเดอร์ เมื่อ slave เกิดความล้มเหลวในการเปิดออเดอร์
  """
  def handle_slave_open_failure(sender_id, master_ticket, reason) do
    sender = Accounts.get_trading_account!(sender_id)
    if sender.copy_mode == "1TO1" do
      partner_id = find_partner_id(sender)
      if partner_id do
        # 1. ค้นหา master_trade_id จาก master_ticket ที่ยัง OPEN อยู่ แล้วแจ้งปิดที่ DB + EA
        # CopyTrade.TradePairContext.mark_master_trade_as_closed(partner_id, master_ticket)
        IO.puts "🔔 [1TO1] Notifying Master #{partner_id} to close Master Ticket #{master_ticket} due to Slave open failure."
        # 2. ส่งสัญญาณปิดออเดอร์กลับไปยัง EA ของ Master
        case Registry.lookup(CopyTrade.Registry, "account:#{partner_id}") do
          [{pid, _}] ->
            IO.puts "🔔 Sending CMD_SYNC_CLOSE to Master #{partner_id} for Master Ticket #{master_ticket}"
            send(pid, {:direct_signal, %{action: "CMD_SYNC_CLOSE", master_ticket: master_ticket, reason: reason}})
          [] ->
            :ok
        end
      end
    end
  end

  def close_master_after_so(sender_id, slave_ticket) do
    sender = Accounts.get_trading_account!(sender_id)
    if sender.copy_mode == "1TO1" do
      partner_id = find_partner_id(sender)
      if partner_id do
        # 1. ค้นหา master_ticket จาก slave_ticket ที่เพิ่งถูกปิดจาก SO
        case CopyTrade.TradePairContext.get_master_ticket_by_slave(partner_id, slave_ticket) do
          nil ->
            Logger.error("❌ [1TO1] No master_ticket found for slave_ticket #{slave_ticket}")
          master_ticket ->
            Logger.info("🔔 [1TO1] Notifying Master #{partner_id} to close Master Ticket #{master_ticket} due to Slave STOP OUT.")
            # 2. ส่งสัญญาณปิดออเดอร์กลับไปยัง EA ของ Master
            case Registry.lookup(CopyTrade.Registry, "account:#{partner_id}") do
              [{pid, _}] ->
                Logger.info("🔔 Sending CMD_SYNC_CLOSE to Master #{partner_id} for Master Ticket #{master_ticket}")
                send(pid, {:direct_signal, %{action: "CMD_SYNC_CLOSE", master_ticket: master_ticket, reason: "slave stop out"}})
              [] ->
                :ok
            end
        end
      end
    end
  end

  # Helper สำหรับหา Partner ID แบบไป-กลับ
  defp find_partner_id(account) do
    cond do
      # ถ้าผู้ส่งเป็น Master และมี partner_id ผูกไว้
      account.partner_id -> account.partner_id

      # ถ้าผู้ส่งเป็น Slave (ต้องหาว่าใครเป็น Master ที่ผูก partner_id มาหาเรา)
      true ->
        import Ecto.Query
        CopyTrade.Repo.one(from t in TradingAccount, where: t.partner_id == ^account.id, select: t.id)
    end
  end
end
