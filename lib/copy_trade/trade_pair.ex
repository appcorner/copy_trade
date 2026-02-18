defmodule CopyTrade.TradePair do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trade_pairs" do
    # field :master_ticket, :integer
    field :slave_ticket, :integer
    # field :symbol, :string
    field :status, :string # PENDING, OPEN, CLOSED
    field :open_price, :float
    field :close_price, :float
    field :profit, :float
    field :opened_at, :utc_datetime
    field :closed_at, :utc_datetime

    # field :type, :string        # BUY / SELL
    # field :volume, :float       # Lot ของ Master
    # field :sl, :float           # Stop Loss
    # field :tp, :float           # Take Profit
    field :slave_volume, :float # Lot ที่ Slave เปิดได้จริง
    field :slave_type, :string  # BUY / SELL ของ Slave

    # field :master_id, :id       # เพิ่ม master_id

    # ผูกกับ User (Follower)
    # ผูกกับ Account (Follower)
    belongs_to :account, CopyTrade.Accounts.TradingAccount, foreign_key: :account_id
    belongs_to :master_trade, CopyTrade.MasterTrade

    timestamps()
  end

  def changeset(pair, attrs) do
    pair
    |> cast(attrs, [:account_id, :master_trade_id, :slave_ticket, :status, :open_price, :close_price, :profit, :slave_volume, :slave_type])
    |> validate_required([:account_id, :master_trade_id, :status])
  end
end
