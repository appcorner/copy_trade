defmodule CopyTradeWeb.WebhookController do
  use CopyTradeWeb, :controller
  require Logger

  # ปิดการเช็ค CSRF Token สำหรับ API (เพราะ MT5 ไม่มี Token นี้)
  plug :accepts, ["json"]

  def create(conn, params) do
    # params คือ JSON ที่ Master ส่งมา
    # หน้าตาประมาณ: %{"symbol" => "XAUUSD", "action" => "BUY", "price" => 2050.0}

    Logger.info("📩 Received Webhook from Master: #{inspect(params)}")

    # แปลงข้อมูลให้ตรงกับ format ที่ Worker เราใช้
    signal = %{
      symbol: params["symbol"],
      action: String.upcase(params["action"]), # มั่นใจว่าเป็นตัวใหญ่
      price: params["price"]
    }

    # 🔥 จุดสำคัญ: Broadcast เข้า PubSub เหมือนตอนเรากดปุ่มหน้า Admin เป๊ะ!
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "gold_signals", {:trade_signal, signal})

    # ตอบกลับ Master ว่า "ได้รับแล้วจ้า"
    conn
    |> put_status(:ok)
    |> json(%{status: "ok", message: "Signal Broadcasted"})
  end
end
