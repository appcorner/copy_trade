defmodule CopyTrade.TradePairContext do
  import Ecto.Query, warn: false
  alias CopyTrade.Repo
  alias CopyTrade.TradePair

  # 1. สร้างคู่บันทึกใหม่ (ตอนเปิดออเดอร์สำเร็จ)
  def create_pair(attrs) do
    %TradePair{}
    |> TradePair.changeset(attrs)
    |> Repo.insert()
  end

  # 2. เช็คว่า Master Ticket นี้เคยเปิดให้ User นี้หรือยัง? (ป้องกันซ้ำ)
  def exists?(user_id, master_ticket) do
    query = from t in TradePair,
      where: t.user_id == ^user_id and t.master_ticket == ^master_ticket

    Repo.exists?(query)
  end

  # 3. หา Slave Ticket จาก Master Ticket (เอาไว้ใช้ตอนสั่งปิด)
  def get_slave_ticket(user_id, master_ticket) do
    query = from t in TradePair,
      where: t.user_id == ^user_id and t.master_ticket == ^master_ticket and t.status == "OPEN",
      select: t.slave_ticket

    Repo.one(query)
  end

  # 4. อัปเดตสถานะว่าปิดแล้ว
  def mark_as_closed(user_id, master_ticket, close_price, profit) do
    # หาใบที่ยัง OPEN อยู่
    case Repo.get_by(TradePair, user_id: user_id, master_ticket: master_ticket, status: "OPEN") do
      nil -> {:error, :not_found}
      pair ->
        pair
        |> Ecto.Changeset.change(%{status: "CLOSED", close_price: close_price, profit: profit})
        |> Repo.update()
    end
  end

  # ฟังก์ชันสำหรับอัปเดต ticket หลังเปิดสำเร็จ
  def update_slave_ticket(user_id, master_ticket, slave_ticket) do
    TradePair
    |> Repo.get_by(user_id: user_id, master_ticket: master_ticket, status: "PENDING")
    |> case do
      nil ->
        # อาจจะเกิด Race Condition หรือหาไม่เจอ
        nil
      pair ->
        pair
        |> Ecto.Changeset.change(%{slave_ticket: slave_ticket, status: "OPEN"})
        |> Repo.update()
    end
  end
end
