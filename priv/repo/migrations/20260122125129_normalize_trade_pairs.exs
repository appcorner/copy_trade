defmodule CopyTrade.Repo.Migrations.NormalizeTradePairs do
  use Ecto.Migration

  def change do
    alter table(:trade_pairs) do
      # 1. เพิ่ม FK เชื่อมไปหา MasterTrade (ถ้ายังไม่ได้ทำใน step ก่อน)
      # add :master_trade_id, references(:master_trades, on_delete: :nothing)

      # 2. ลบคอลัมน์ที่ซ้ำกับ MasterTrade ทิ้ง 🗑️
      remove :symbol
      remove :type
      remove :volume        # Lot ของ Master
      remove :sl
      remove :tp
      # remove :open_price    # ราคาเปิดของ Master (หรือ price)
      remove :master_ticket # ถ้าอยาก normalize สุดๆ ก็เอาออก (ใช้ master_trade_id อ้างอิงแทน)
      remove :master_id     # เอาออกได้ เพราะ master_trade รู้จัก master_id อยู่แล้ว
    end

    # # สร้าง Index สำหรับ FK ใหม่
    # create index(:trade_pairs, [:master_trade_id])
  end
end
