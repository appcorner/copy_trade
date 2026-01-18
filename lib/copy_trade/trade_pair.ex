defmodule CopyTrade.TradePair do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trade_pairs" do
    field :master_ticket, :integer
    field :slave_ticket, :integer
    field :symbol, :string
    field :status, :string # PENDING, OPEN, CLOSED
    field :open_price, :float
    field :close_price, :float
    field :profit, :float
    field :opened_at, :utc_datetime
    field :closed_at, :utc_datetime

    # ผูกกับ User (Follower)
    belongs_to :user, CopyTrade.Accounts.User

    timestamps()
  end

  def changeset(pair, attrs) do
    pair
    |> cast(attrs, [:user_id, :master_ticket, :slave_ticket, :symbol, :status, :open_price, :close_price, :profit])
    |> validate_required([:user_id, :master_ticket, :symbol, :status])
  end
end
