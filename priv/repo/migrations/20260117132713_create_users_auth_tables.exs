defmodule CopyTrade.Repo.Migrations.CreateUsersAuthTables do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", ""

    create table(:users) do
      add :email, :citext, null: false
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime

      # 🔥 เพิ่ม 4 บรรทัดนี้ครับ
      add :role, :string, default: "follower" # admin, master, follower
      add :api_key, :string                   # รหัสลับสำหรับ EA
      add :master_token, :string              # รหัสสำหรับแจกให้คนอื่น Copy (เฉพาะ Master)
      add :following_id, references(:users, on_delete: :nilify_all) # ผูกว่ากำลังตามใครอยู่

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])

    # 🔥 เพิ่ม Index ให้ API Key กับ Master Token เพื่อให้ค้นหาเร็วๆ
    create unique_index(:users, [:api_key])
    create unique_index(:users, [:master_token])

    create table(:users_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:users_tokens, [:user_id])
    create unique_index(:users_tokens, [:context, :token])
  end
end
