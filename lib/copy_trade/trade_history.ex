defmodule CopyTrade.TradeHistory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trade_histories" do
    field :user_id, :string
    field :symbol, :string
    field :action, :string
    field :price, :float
    field :volume, :float
    field :ticket, :integer
    field :status, :string
    field :execution_time_ms, :integer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(trade_history, attrs) do
    trade_history
    |> cast(attrs, [:user_id, :symbol, :action, :price, :volume, :ticket, :status, :execution_time_ms])
    |> validate_required([:user_id, :symbol, :action, :price, :volume, :ticket, :status, :execution_time_ms])
  end
end
