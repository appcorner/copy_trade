defmodule CopyTrade.Repo.Migrations.CreateTradePairs do
  use Ecto.Migration

  def change do
    create table(:trade_pairs) do
      add :user_id, :string
      add :master_ticket, :integer
      add :slave_ticket, :integer
      add :symbol, :string
      add :status, :string
      add :open_price, :float
      add :close_price, :float
      add :profit, :float

      timestamps(type: :utc_datetime)
    end

    # 🔥 สำคัญมาก: ห้าม User คนเดิม เปิด Master Ticket เดิมซ้ำ
    create unique_index(:trade_pairs, [:user_id, :master_ticket])
  end
end
