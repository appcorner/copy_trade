defmodule CopyTrade.Accounts.TradingAccount do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trading_accounts" do
    field :name, :string
    field :role, :string
    field :api_key, :string
    field :master_token, :string
    field :copy_mode, :string, default: "PUBSUB"
    field :is_active, :boolean, default: true

    belongs_to :user, CopyTrade.Accounts.User
    
    # Self-referencing associations for copy trading logic
    belongs_to :partner, CopyTrade.Accounts.TradingAccount
    belongs_to :following, CopyTrade.Accounts.TradingAccount
    
    # Association for those who follow this account
    has_many :followers, CopyTrade.Accounts.TradingAccount, foreign_key: :following_id
    
    # Association for partner (inverse)
    has_one :partner_account, CopyTrade.Accounts.TradingAccount, foreign_key: :partner_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(trading_account, attrs) do
    trading_account
    |> cast(attrs, [:name, :role, :api_key, :master_token, :copy_mode, :is_active, :user_id, :partner_id, :following_id])
    |> validate_required([:name, :role, :user_id, :is_active])
    |> validate_inclusion(:role, ["master", "follower"])
    |> validate_inclusion(:copy_mode, ["1TO1", "PUBSUB", "RECORD"])
    |> unique_constraint(:api_key)
    |> unique_constraint(:master_token)
    |> put_api_keys()
  end

  defp put_api_keys(changeset) do
    if get_field(changeset, :api_key) == nil do
      changeset
      |> put_change(:api_key, generate_key("sk_live_"))
      |> generate_master_token_if_needed()
    else
      changeset
    end
  end

  defp generate_master_token_if_needed(changeset) do
    if get_field(changeset, :role) == "master" && get_field(changeset, :master_token) == nil do
      put_change(changeset, :master_token, generate_key("MST-"))
    else
      changeset
    end
  end

  defp generate_key(prefix) do
    random = :crypto.strong_rand_bytes(16) |> Base.encode16() |> String.downcase()
    prefix <> random
  end
end
