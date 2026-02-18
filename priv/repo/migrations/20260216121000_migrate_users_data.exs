defmodule CopyTrade.Repo.Migrations.MigrateUsersData do
  use Ecto.Migration

  def up do
    # 1. Copy basic data from users to trading_accounts
    execute """
    INSERT INTO trading_accounts (user_id, name, role, api_key, master_token, copy_mode, is_active, inserted_at, updated_at)
    SELECT id, name, role, api_key, master_token, copy_mode, true, inserted_at, updated_at
    FROM users;
    """

    # 2. Update following_id (Self-referencing)
    # Logic: Set TA.following_id to the TA.id of the user that the current user is following
    execute """
    UPDATE trading_accounts
    SET following_id = master_ta.id
    FROM trading_accounts AS master_ta
    JOIN users AS u ON u.following_id = master_ta.user_id
    WHERE trading_accounts.user_id = u.id
      AND u.following_id IS NOT NULL;
    """

    # 3. Update partner_id (Self-referencing)
    # Logic: Set TA.partner_id to the TA.id of the user that is the current user's partner
    execute """
    UPDATE trading_accounts
    SET partner_id = partner_ta.id
    FROM trading_accounts AS partner_ta
    JOIN users AS u ON u.partner_id = partner_ta.user_id
    WHERE trading_accounts.user_id = u.id
      AND u.partner_id IS NOT NULL;
    """
  end

  def down do
    execute "TRUNCATE TABLE trading_accounts;"
  end
end
