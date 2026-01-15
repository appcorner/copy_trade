defmodule CopyTrade.Repo do
  use Ecto.Repo,
    otp_app: :copy_trade,
    adapter: Ecto.Adapters.Postgres
end
