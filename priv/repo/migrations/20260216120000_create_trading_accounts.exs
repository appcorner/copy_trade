defmodule CopyTrade.Repo.Migrations.CreateTradingAccounts do
  use Ecto.Migration

  def change do
    create table(:trading_accounts) do
      add :user_id, references(:users, on_delete: :nothing)
      add :name, :string
      add :role, :string
      add :api_key, :string
      add :master_token, :string, default: nil
      add :copy_mode, :string, default: "PUBSUB"
      add :partner_id, references(:trading_accounts, on_delete: :nothing)
      add :following_id, references(:trading_accounts, on_delete: :nothing)
      add :is_active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:trading_accounts, [:user_id])
    create index(:trading_accounts, [:partner_id])
    create index(:trading_accounts, [:following_id])
    create unique_index(:trading_accounts, [:api_key])
    create unique_index(:trading_accounts, [:master_token])
  end
end
