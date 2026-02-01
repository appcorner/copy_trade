defmodule CopyTrade.Repo.Migrations.CreateUserSymbols do
  use Ecto.Migration

  def change do
    create table(:user_symbols) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :symbol, :string, null: false
      add :contract_size, :float, default: 100000.0
      add :digits, :integer, default: 5

      timestamps(autofill_microsecond: false) # ใช้เทคนิคที่เราคุยกันเพื่อกัน Error
    end

    # สร้าง Index เพื่อให้ Query ข้อมูลได้เร็วขึ้นเวลา EA ส่งราคามา
    create unique_index(:user_symbols, [:user_id, :symbol])
  end
end
