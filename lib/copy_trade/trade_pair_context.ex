defmodule CopyTrade.TradePairContext do
  @moduledoc """
  Context สำหรับจัดการคู่เทรด (Trade Pairs)
  บันทึกความสัมพันธ์ระหว่าง Master Ticket <-> Slave Ticket
  """
  import Ecto.Query, warn: false
  alias CopyTrade.Repo
  alias CopyTrade.TradePair # (ต้องสร้าง Schema นี้ด้วย เดี๋ยวผมให้ code ต่อไป)
  alias CopyTrade.MasterTrade
  alias CopyTrade.Cache.SymbolCache

  # 1. สร้างคู่เทรดใหม่ (สถานะ PENDING)
  def create_trade_pair(attrs) do
    %TradePair{}
    |> TradePair.changeset(attrs)
    |> Repo.insert()
  end

  # 2. เช็คว่า Master Ticket นี้เคยเปิดไปหรือยัง (กันซ้ำ)
  def exists?(user_id, master_ticket) do
    query = from t in TradePair,
      join: m in assoc(t, :master_trade),
      where: t.user_id == ^user_id and m.ticket == ^master_ticket

    Repo.exists?(query)
  end

  # 3. อัปเดต Slave Ticket (เมื่อ EA ตอบกลับ ACK_OPEN)
  def update_slave_ticket(user_id, master_ticket, slave_ticket, slave_volume, slave_type) do
    # หา pair ที่ตรงกันและยังเป็น PENDING
    query = from t in TradePair,
      join: m in assoc(t, :master_trade),
      where: t.user_id == ^user_id and m.ticket == ^master_ticket and t.status == "PENDING"

    case Repo.one(query) do
      nil -> {:error, :not_found}
      pair ->
        pair
        |> Ecto.Changeset.change(%{
          slave_ticket: slave_ticket,
          slave_volume: slave_volume,
          slave_type: slave_type,
          status: "OPEN",
          opened_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
        |> Repo.update()
    end
  end

  # 4. ดึง Slave Ticket เพื่อไปสั่งปิด
  def get_slave_ticket(user_id, master_ticket) do
    query = from t in TradePair,
      join: m in assoc(t, :master_trade),
      where: t.user_id == ^user_id and m.ticket == ^master_ticket,
      select: t.slave_ticket

    Repo.one(query)
  end

  # 5. บันทึกการปิดออเดอร์ (เมื่อ EA ตอบกลับ ACK_CLOSE)
  def mark_as_closed(user_id, master_ticket, close_price, profit) do
    query = from t in TradePair,
      join: m in assoc(t, :master_trade),
      where: t.user_id == ^user_id and m.ticket == ^master_ticket

    case Repo.one(query) do
      nil -> {:error, :not_found}
      pair ->
        pair
        |> Ecto.Changeset.change(%{
          status: "CLOSED",
          close_price: close_price,
          profit: profit,
          closed_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
        |> Repo.update()
    end
  end

  # 6. ดึงออเดอร์ที่กำลังทำงานอยู่ (OPEN หรือ PENDING)
  def list_active_pairs(user_id) do
    from(t in TradePair,
      join: m in assoc(t, :master_trade),
      where: t.user_id == ^user_id and t.status in ["OPEN"],

      # Preload เพื่อให้ใน Code เรียก t.master_trade.symbol ได้
      preload: [master_trade: m],

      order_by: [desc: t.inserted_at],

      select: t
    )
    |> Repo.all()
  end

  # 7. ดึงประวัติการเทรดที่จบแล้ว (CLOSED)
  def list_closed_pairs(user_id, limit \\ 50) do
    from(t in TradePair,
      join: m in assoc(t, :master_trade),
      where: t.user_id == ^user_id and t.status == "CLOSED" and t.close_price > 0.0,
      order_by: [desc: t.closed_at],
      limit: ^limit,
      preload: [master_trade: m]
    )
    |> Repo.all()
  end

  # 8. คำนวณกำไรรวม
  def get_total_profit(user_id) do
    query = from t in TradePair,
      where: t.user_id == ^user_id and t.status == "CLOSED" and t.close_price > 0.0,
      select: sum(t.profit)

    Repo.one(query) || 0.0
  end


  # 1. ฟังก์ชันใหม่: บันทึก Signal ของ Master ลง DB
  def create_master_trade(attrs) do
    %MasterTrade{}
    |> MasterTrade.changeset(attrs)
    |> Repo.insert()
  end

  # 2. ฟังก์ชันเดิม: แต่ปรับให้รับ master_trade_id
  # def create_trade_pair(attrs) do
  #   %TradePair{}
  #   |> TradePair.changeset(attrs)
  #   |> Repo.insert()
  # end

  # 3. (Optional) ฟังก์ชัน Update Master Trade (ตอนปิดออเดอร์)
  def close_master_trade(master_id, ticket, close_price, profit) do
    case Repo.get_by(MasterTrade, master_id: master_id, ticket: ticket) do
      nil -> {:error, :not_found}
      trade ->
        trade
        |> Ecto.Changeset.change(%{
          status: "CLOSED",
          close_price: close_price,
          profit: profit
        })
        |> Repo.update()
    end
  end

  # 4. ฟังก์ชันปิด Master Trade และ Trade Pairs ของ Followers พร้อมกัน
  def close_master_and_followers(master_id, master_ticket, close_price, actual_profit) do
    Repo.transaction(fn ->
      # 1. ดึงข้อมูล Master เพื่อเอา Volume และ Type มาเป็นค่าคงที่
      query_master = Repo.get_by(MasterTrade, ticket: master_ticket, master_id: master_id, status: "OPEN")

      case query_master do
        nil ->
          IO.puts "Warning: Master ticket #{master_ticket} not found or already closed."
          :ok
        master ->
          # 2. อัปเดตสถานะ Master เป็น CLOSED
          master
          |> Ecto.Changeset.change(%{
            status: "CLOSED",
            close_price: close_price,
            profit: actual_profit
          })
          |> Repo.update!()

          # 3. ดึงรายการ Slave ทั้งหมดที่เปิดอยู่มาจัดการ
          query = from(p in TradePair,
            join: m in assoc(p, :master_trade),
            where: m.master_id == ^master_id and
                  m.ticket == ^master_ticket and
                  p.status == "OPEN")

          slave_pairs = Repo.all(query)

          # 4. วนลูปอัปเดตรายตัวเพื่อป้องกันปัญหา undefined variable "p"
          Enum.each(slave_pairs, fn p ->
            # คำนวณกำไรตามสัดส่วนและทิศทาง
            direction_mult = if(p.slave_type == master.type, do: 1.0, else: -1.0)

            # ป้องกันการหารด้วยศูนย์ (Division by Zero)
            slave_profit =
              if master.volume > 0 do
                actual_profit * (p.slave_volume / master.volume) * direction_mult
              else
                0.0
              end

            p
            |> Ecto.Changeset.change(%{
              status: "CLOSED",
              close_price: close_price,
              profit: slave_profit
            })
            |> Repo.update!()
          end)
          :ok
      end
    end)
  end

  @doc """
  คำนวณกำไร/ขาดทุนแบบเรียลไทม์ (Floating P/L) โดยรับราคาล่าสุดจาก Socket Assigns
  """
  def calculate_floating_profit(trade_pair, prices) when is_map(prices) do
    # IO.inspect(prices, label: ">>> prices")
    # ดึงข้อมูล Master เพื่อเอา user_id มาเป็น Key
    master = trade_pair.master_trade

    slave_symbol_info = SymbolCache.get_info(trade_pair.user_id, master.symbol) || %{contract_size: 100000.0, digits: 5}

    # ตรวจสอบว่าใน Map 'prices' มีราคาของ Master คนนี้และ Symbol นี้อยู่หรือไม่
    case Map.get(prices, {master.master_id, master.symbol}) do
      nil ->
        0.0 # หากยังไม่มีข้อมูลราคา ให้แสดงกำไรเป็น 0.0 ไปก่อน เพื่อป้องกัน Error

      price_data ->
        # ส่งไปคำนวณตามสูตรคณิตศาสตร์
        do_calc_pl(trade_pair, slave_symbol_info.contract_size, price_data)
    end
  end

  # กรณีเรียกใช้โดยไม่ส่ง Map ราคามา (Fallback)
  def calculate_floating_profit(_trade_pair, _prices), do: 0.0

  # สูตรคำนวณกำไรสุทธิ (Private Function)
  defp do_calc_pl(trade, contract_size, %{bid: bid, ask: ask}) do
    # ดึงประเภทไม้ (slave_type) จากโครงสร้างข้อมูล: 0 = BUY, 1 = SELL
    case trade.slave_type do
      "BUY" ->
        # สูตร: (ราคา Bid ปัจจุบัน - ราคาเปิด) * Lot * ContractSize
        (bid - trade.open_price) * trade.slave_volume * contract_size

      "SELL" ->
        # สูตร: (ราคาเปิด - ราคา Ask ปัจจุบัน) * Lot * ContractSize
        (trade.open_price - ask) * trade.slave_volume * contract_size
      _ ->
        0.0
    end
  end

  def reconcile_master_orders(master_id, actual_master_tickets) do
    Repo.transaction(fn ->
      # 1. ค้นหา Master Ticket ใน DB ที่สถานะเป็น OPEN แต่ไม่อยู่ใน Snapshot ที่ส่งมา
      query = from(m in MasterTrade,
              where: m.master_id == ^master_id and
                    m.status == "OPEN" and
                    m.ticket not in ^actual_master_tickets)

      dead_master_tickets = Repo.all(from(m in query, select: m.ticket))

      if length(dead_master_tickets) > 0 do
        # 2. ปิดไม้ Master ใน DB
        Repo.update_all(query, set: [status: "CLOSED"])

        # 3. สำคัญมาก: สั่งปิดไม้ Slave (TradePair) ทุกตัวที่ตาม Master Ticket เหล่านี้อยู่
        # เพื่อให้ระบบ Slave รู้ว่าต้องกวาดล้างฝั่งตัวเองด้วย
        from(p in TradePair,
            join: m in assoc(p, :master_trade),
            where: m.ticket in ^dead_master_tickets and p.status == "OPEN")
        |> Repo.update_all(set: [status: "CLOSED"])
      end

      :ok
    end)
  end

  def reconcile_slave_orders(follower_id, actual_slave_tickets) do
    Repo.transaction(fn ->
      # --- ส่วนที่ 1: กวาดล้าง DB (ไม้ที่ใน DB มีแต่ใน EA ไม่มี) ---
      # ค้นหาไม้ที่ใน DB บอกว่า OPEN แต่ใน EA ปิดไปแล้ว
      db_open_tickets_query = from p in TradePair,
                              where: p.user_id == ^follower_id and p.status == "OPEN",
                              select: p.slave_ticket

      db_tickets = Repo.all(db_open_tickets_query)

      # ไม้ที่ต้องอัปเดตเป็น CLOSED ใน DB
      to_close_in_db = db_tickets -- actual_slave_tickets

      if length(to_close_in_db) > 0 do
        from(p in TradePair, where: p.user_id == ^follower_id and p.slave_ticket in ^to_close_in_db)
        |> Repo.update_all(set: [status: "CLOSED"])
      end

      # --- ส่วนที่ 2: ตรวจจับไม้ผี (ไม้ที่ใน EA มีแต่ใน DB ไม่มี) ---
      # ไม้ที่เปิดอยู่ใน EA แต่ระบบ Copy Trade ไม่รู้จัก (อาจจะเปิดมือเอง)
      zombie_in_ea = actual_slave_tickets -- db_tickets

      zombie_in_ea # คืนค่ารายการไม้ผีกลับไปเพื่อให้ TCP Handler สั่งปิด
    end)
  end
end
