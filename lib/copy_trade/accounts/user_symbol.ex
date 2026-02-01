defmodule CopyTrade.Accounts.UserSymbol do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_symbols" do
    field :symbol, :string
    field :contract_size, :float
    field :digits, :integer

    belongs_to :user, CopyTrade.Accounts.User

    timestamps(autofill_microsecond: false)
  end

  def changeset(user_symbol, attrs) do
    user_symbol
    |> cast(attrs, [:symbol, :contract_size, :digits, :user_id])
    |> validate_required([:symbol, :contract_size, :user_id])
    |> unique_constraint([:user_id, :symbol])
  end
end
