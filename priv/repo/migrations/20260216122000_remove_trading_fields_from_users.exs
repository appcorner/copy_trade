defmodule CopyTrade.Repo.Migrations.RemoveTradingFieldsFromUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      remove :role
      remove :api_key
      remove :master_token
      remove :copy_mode
      remove :partner_id
      remove :following_id
    end
  end
end
