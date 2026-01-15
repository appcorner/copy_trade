defmodule CopyTrade.TradePair do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trade_pairs" do
    field :user_id, :string
    field :master_ticket, :integer
    field :slave_ticket, :integer
    field :symbol, :string
    field :status, :string
    field :open_price, :float
    field :close_price, :float
    field :profit, :float

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(trade_pair, attrs) do
    trade_pair
    |> cast(attrs, [:user_id, :master_ticket, :slave_ticket, :symbol, :status, :open_price, :close_price, :profit])
    |> validate_required([:user_id, :master_ticket, :slave_ticket, :symbol, :status, :open_price, :close_price, :profit])
  end
end
