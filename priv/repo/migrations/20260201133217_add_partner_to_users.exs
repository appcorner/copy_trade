defmodule CopyTrade.Repo.Migrations.AddPartnerToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # เก็บ ID ของคู่หู (Partner)
      add :partner_id, references(:users, on_delete: :nilify_all)
      add :copy_mode, :string, default: "PUBSUB" # "1TO1" หรือ "PUBSUB"
    end

    # สร้าง Unique Index เพื่อรับประกันว่า 1 Master จะมีแค่ 1 Follower
    # และ Follower 1 คน จะมีแค่ 1 Master เท่านั้น
    create unique_index(:users, [:partner_id])
  end
end
