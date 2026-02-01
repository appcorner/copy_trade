# lib/copy_trade/trade_signal_router.ex
defmodule CopyTrade.TradeSignalRouter do
  require Logger
  alias CopyTrade.Accounts
  alias Phoenix.PubSub

  @doc """
  ฟังก์ชันหลักในการกระจายสัญญาณ
  จะตรวจสอบโหมดของ Master และส่งสัญญาณผ่านช่องทางที่เหมาะสม
  """
  def dispatch(master_id, signal_data) do
    # ดึงข้อมูล Master เพื่อดู copy_mode และ partner_id
    master = Accounts.get_user!(master_id)

    case master.copy_mode do
      "1TO1" ->
        # โหมดคู่แท้: ส่งตรงถึง Partner คนเดียวแบบ Exclusive
        handle_1to1_dispatch(master.partner_id, signal_data)

      "PUBSUB" ->
        # โหมดมหาชน: กระจายผ่าน Phoenix PubSub (Scalable)
        PubSub.broadcast(
          CopyTrade.PubSub,
          "trades:#{master_id}",
          {:signal, signal_data}
        )

      _ ->
        IO.puts "Unknown copy mode for Master #{master_id}"
    end
  end

  # ฟังก์ชันช่วยส่งสัญญาณแบบ Direct (กระซิบ)
  defp handle_1to1_dispatch(nil, _data) do
    IO.puts "Warning: Master is in 1TO1 mode but has no partner assigned."
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
    case Registry.lookup(CopyTrade.Registry, "user:#{partner_id}") do
      [{pid, _}] ->
        send(pid, {:direct_signal, signal_data})
      [] ->
        IO.puts "Partner (User #{partner_id}) is currently offline."
    end
  end

  defp handle_open_1to1(partner_id, signal_data) do
    params = %{
      user_id: partner_id,
      master_id: signal_data.master_id,
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
end
