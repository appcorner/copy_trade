defmodule CopyTrade.Repo.Migrations.FixAllReferences do
  use Ecto.Migration

  def up do
    # 1. Cleaning up constraints manually to avoid "does not exist" or "already exists" errors
    execute "ALTER TABLE trade_pairs DROP CONSTRAINT IF EXISTS trade_pairs_user_id_fkey"
    execute "ALTER TABLE master_trades DROP CONSTRAINT IF EXISTS master_trades_master_id_fkey"
    execute "ALTER TABLE user_symbols DROP CONSTRAINT IF EXISTS user_symbols_user_id_fkey"

    # 2. Renaming columns (renames are atomic, assumes columns exist as user_id)
    rename table(:trade_pairs), :user_id, to: :account_id
    rename table(:user_symbols), :user_id, to: :account_id
    
    # 3. Altering references to point to trading_accounts
    # This will create new constraints.
    # Note: modify/2 will try to create a foreign key constraint.
    
    alter table(:trade_pairs) do
      modify :account_id, references(:trading_accounts, column: :id, on_delete: :nothing)
    end
    
    alter table(:master_trades) do
      # For master_trades, column name is still master_id
      modify :master_id, references(:trading_accounts, column: :id, on_delete: :nothing)
    end
    
    alter table(:user_symbols) do
      modify :account_id, references(:trading_accounts, column: :id, on_delete: :delete_all)
    end
  end

  def down do
    # Revert logic
    # Try to drop the new constraints first
    execute "ALTER TABLE trade_pairs DROP CONSTRAINT IF EXISTS trade_pairs_account_id_fkey"
    execute "ALTER TABLE master_trades DROP CONSTRAINT IF EXISTS master_trades_master_id_fkey"
    execute "ALTER TABLE user_symbols DROP CONSTRAINT IF EXISTS user_symbols_account_id_fkey"

    rename table(:trade_pairs), :account_id, to: :user_id
    rename table(:user_symbols), :account_id, to: :user_id
    
    alter table(:trade_pairs) do
      modify :user_id, references(:users, column: :id, on_delete: :nothing)
    end
    
    alter table(:master_trades) do
      modify :master_id, references(:users, column: :id, on_delete: :nothing)
    end

    alter table(:user_symbols) do
      modify :user_id, references(:users, column: :id, on_delete: :delete_all)
    end
  end
end
