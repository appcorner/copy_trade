defmodule CopyTrade.Repo.Migrations.AddDetailsToTradePairs do
  use Ecto.Migration

  def change do
    alter table(:trade_pairs) do
      add :master_id, references(:users, on_delete: :nothing) # 🔥 เพิ่ม master_id
      add :type, :string        # "BUY" หรือ "SELL"
      add :volume, :float       # Lot ของ Master
      add :sl, :float           # Stop Loss
      add :tp, :float           # Take Profit
      add :slave_volume, :float # Lot ที่ Slave เปิดได้จริง
    end
    
    # สร้าง Index เพื่อให้ค้นหาด้วย master_id เร็วขึ้น
    create index(:trade_pairs, [:master_id])
  end
end
