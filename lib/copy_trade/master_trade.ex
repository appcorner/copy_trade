defmodule CopyTrade.MasterTrade do
  use Ecto.Schema
  import Ecto.Changeset

  schema "master_trades" do
    field :ticket, :integer
    field :symbol, :string
    field :type, :string
    field :price, :float
    field :volume, :float
    field :sl, :float
    field :tp, :float
    field :status, :string
    field :close_price, :float
    field :profit, :float
    field :contract_size, :float, default: 100000.0

    # Relation
    belongs_to :account, CopyTrade.Accounts.TradingAccount, foreign_key: :master_id
    has_many :trade_pairs, CopyTrade.TradePair # 1 Signal มีหลายคนตาม

    timestamps(type: :utc_datetime)
  end

  def changeset(trade, attrs) do
    trade
    |> cast(attrs, [:ticket, :symbol, :type, :price, :volume, :sl, :tp, :status, :master_id, :close_price, :profit, :contract_size])
    |> validate_required([:ticket, :symbol, :type, :master_id])
  end
end
