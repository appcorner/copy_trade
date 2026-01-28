defmodule CopyTrade.Repo.Migrations.ChangeTicketsToBigint do
  use Ecto.Migration

  def up do
    # 1. แก้ตาราง trade_pairs
    alter table(:trade_pairs) do
      modify :slave_ticket, :bigint
    end

    # 2. แก้ตาราง master_trades (ถ้ามี)
    alter table(:master_trades) do
      modify :ticket, :bigint
    end
  end

  def down do
    # เผื่อ rollback (แต่มักจะทำไม่ได้ถ้าข้อมูลเกินไปแล้ว)
    alter table(:trade_pairs) do
      modify :slave_ticket, :integer
    end

    alter table(:master_trades) do
      modify :ticket, :integer
    end
  end
end
