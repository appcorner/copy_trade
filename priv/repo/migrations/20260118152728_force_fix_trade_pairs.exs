defmodule CopyTrade.Repo.Migrations.ForceFixTradePairs do
  use Ecto.Migration

  def change do
    # 1. ลบตารางเก่าทิ้ง (ถ้ามี)
    drop_if_exists table(:trade_pairs)

    # 2. สร้างใหม่ให้ครบทุกช่อง
    create table(:trade_pairs) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :master_ticket, :bigint
      add :slave_ticket, :bigint
      add :symbol, :string
      add :status, :string
      add :open_price, :float
      add :close_price, :float
      add :profit, :float
      add :opened_at, :utc_datetime
      add :closed_at, :utc_datetime

      timestamps()
    end

    create index(:trade_pairs, [:user_id])
    create index(:trade_pairs, [:user_id, :master_ticket])
  end
end
