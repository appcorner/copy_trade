defmodule CopyTrade.Repo.Migrations.AddSlaveTypeToTradePairs do
  use Ecto.Migration

  def change do
    alter table(:trade_pairs) do
      add :slave_type, :string # เก็บ "BUY" หรือ "SELL" ของ Slave จริงๆ
    end
  end
end
