defmodule CopyTrade.TradePairContext do
  @moduledoc """
  Context สำหรับจัดการคู่เทรด (Trade Pairs)
  บันทึกความสัมพันธ์ระหว่าง Master Ticket <-> Slave Ticket
  """
  import Ecto.Query, warn: false
  alias CopyTrade.Repo
  alias CopyTrade.TradePair # (ต้องสร้าง Schema นี้ด้วย เดี๋ยวผมให้ code ต่อไป)

  # 1. สร้างคู่เทรดใหม่ (สถานะ PENDING)
  def create_pair(attrs) do
    %TradePair{}
    |> TradePair.changeset(attrs)
    |> Repo.insert()
  end

  # 2. เช็คว่า Master Ticket นี้เคยเปิดไปหรือยัง (กันซ้ำ)
  def exists?(user_id, master_ticket) do
    query = from t in TradePair,
      where: t.user_id == ^user_id and t.master_ticket == ^master_ticket

    Repo.exists?(query)
  end

  # 3. อัปเดต Slave Ticket (เมื่อ EA ตอบกลับ ACK_OPEN)
  def update_slave_ticket(user_id, master_ticket, slave_ticket) do
    # หา pair ที่ตรงกันและยังเป็น PENDING
    pair = Repo.get_by(TradePair, user_id: user_id, master_ticket: master_ticket)

    case pair do
      nil -> {:error, :not_found}
      pair ->
        pair
        |> Ecto.Changeset.change(%{
          slave_ticket: slave_ticket,
          status: "OPEN",
          opened_at: DateTime.truncate(DateTime.utc_now(), :second)
        })
        |> Repo.update()
    end
  end

  # 4. ดึง Slave Ticket เพื่อไปสั่งปิด
  def get_slave_ticket(user_id, master_ticket) do
    query = from t in TradePair,
      where: t.user_id == ^user_id and t.master_ticket == ^master_ticket,
      select: t.slave_ticket

    Repo.one(query)
  end

  # 5. บันทึกการปิดออเดอร์ (เมื่อ EA ตอบกลับ ACK_CLOSE)
  def mark_as_closed(user_id, master_ticket, close_price, profit) do
    pair = Repo.get_by(TradePair, user_id: user_id, master_ticket: master_ticket)

    case pair do
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
      where: t.user_id == ^user_id and t.status in ["OPEN", "PENDING"],
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  # 7. ดึงประวัติการเทรดที่จบแล้ว (CLOSED)
  def list_closed_pairs(user_id, limit \\ 50) do
    from(t in TradePair,
      where: t.user_id == ^user_id and t.status == "CLOSED",
      order_by: [desc: t.closed_at],
      limit: ^limit
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
end
