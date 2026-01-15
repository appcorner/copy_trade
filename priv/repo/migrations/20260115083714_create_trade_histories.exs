defmodule CopyTrade.Repo.Migrations.CreateTradeHistories do
  use Ecto.Migration

  def change do
    create table(:trade_histories) do
      add :user_id, :string
      add :symbol, :string
      add :action, :string
      add :price, :float
      add :volume, :float
      add :ticket, :integer
      add :status, :string
      add :execution_time_ms, :integer

      timestamps(type: :utc_datetime)
    end
  end
end
