defmodule CopyTrade.Repo.Migrations.AddContractSizeToMasterTrades do
  use Ecto.Migration

  def change do
    alter table(:master_trades) do
      # เพิ่ม Contract Size เพื่อใช้คำนวณกำไรตามประเภทสินทรัพย์
      add :contract_size, :float, default: 100_000.0
    end
  end
end
