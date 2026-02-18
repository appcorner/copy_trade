defmodule CopyTrade.Accounts.UserSymbol do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_symbols" do
    field :symbol, :string
    field :contract_size, :float
    field :digits, :integer

    belongs_to :account, CopyTrade.Accounts.TradingAccount, foreign_key: :account_id

    timestamps(autofill_microsecond: false)
  end

  def changeset(user_symbol, attrs) do
    user_symbol
    |> cast(attrs, [:symbol, :contract_size, :digits, :account_id])
    |> validate_required([:symbol, :contract_size, :account_id])
    |> unique_constraint([:account_id, :symbol])
  end
end
