defmodule CopyTradeWeb.WebhookController do
  use CopyTradeWeb, :controller
  require Logger

  plug :accepts, ["json"]

  def create(conn, params) do
    # รับ JSON จาก Master
    Logger.info("📩 Webhook: #{inspect(params)}")

    # แปลงข้อมูล
    signal = %{
      symbol: params["symbol"],
      action: String.upcase(params["action"]),
      price: params["price"]
    }

    # กระจายข่าวเข้า PubSub (Worker จะได้รับตรงนี้)
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "gold_signals", {:trade_signal, signal})

    conn
    |> put_status(:ok)
    |> json(%{status: "ok"})
  end
end
