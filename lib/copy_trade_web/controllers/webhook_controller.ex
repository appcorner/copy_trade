defmodule CopyTradeWeb.WebhookController do
  use CopyTradeWeb, :controller
  require Logger

  plug :accepts, ["json"]

  def create(conn, params) do
    Logger.info("📩 Webhook V2: #{inspect(params)}")

    # แปลงข้อมูลเป็น Signal Struct ที่ชัดเจน
    signal = %{
      symbol: params["symbol"],
      action: params["action"], # "OPEN_BUY", "OPEN_SELL", "CLOSE"
      master_ticket: params["ticket"], # 🔥 ของใหม่
      volume: params["volume"],        # 🔥 ของใหม่
      price: params["price"]
    }

    # Broadcast เข้า PubSub
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "gold_signals", {:trade_signal, signal})

    conn
    |> put_status(:ok)
    |> json(%{status: "received"})
  end
end
