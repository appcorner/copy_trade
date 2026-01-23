defmodule CopyTrade.Repo.Migrations.CreateMasterTrades do
  use Ecto.Migration

  def change do
    # 1. สร้างตารางเก็บ Signal ของ Master
    create table(:master_trades) do
      add :ticket, :integer        # Ticket เดิมของ Master
      add :symbol, :string
      add :type, :string          # BUY/SELL
      add :price, :float          # Open Price
      add :volume, :float         # Lot
      add :sl, :float
      add :tp, :float
      add :status, :string        # OPEN, CLOSED

      add :close_price, :float
      add :profit, :float

      add :master_id, references(:users, on_delete: :nothing) # ผูกกับ User (Master)

      timestamps(type: :utc_datetime)
    end

    # สร้าง Index ให้หา Ticket เร็วๆ
    create unique_index(:master_trades, [:master_id, :ticket])

    # 2. ปรับตาราง TradePair ให้มาชี้ที่นี่
    alter table(:trade_pairs) do
      add :master_trade_id, references(:master_trades, on_delete: :nothing)
    end

    # สร้าง Index สำหรับการ Join
    create index(:trade_pairs, [:master_trade_id])
  end
end
