defmodule CopyTrade.TradePairContext do
  @moduledoc """
  Context สำหรับจัดการคู่เทรด (Trade Pairs)
  บันทึกความสัมพันธ์ระหว่าง Master Ticket <-> Slave Ticket
  """
  import Ecto.Query, warn: false
  alias CopyTrade.Repo
  alias CopyTrade.TradePair # (ต้องสร้าง Schema นี้ด้วย เดี๋ยวผมให้ code ต่อไป)
  alias CopyTrade.MasterTrade

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
      where: t.user_id == ^user_id and t.status == "CLOSED",
      order_by: [desc: t.closed_at],
      limit: ^limit,
      preload: [master_trade: m]
    )
    |> Repo.all()
  end

  # 8. คำนวณกำไรรวม
  def get_total_profit(user_id) do
    query = from t in TradePair,
      where: t.user_id == ^user_id and t.status == "CLOSED",
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
end
