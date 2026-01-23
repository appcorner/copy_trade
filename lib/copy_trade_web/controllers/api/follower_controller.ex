defmodule CopyTradeWeb.Api.FollowerController do
  use CopyTradeWeb, :controller
  alias CopyTrade.Accounts

  # EA จะยิงมาที่: GET /api/check_status?api_key=XXXXX
  def check_status(conn, %{"api_key" => api_key}) do
    case Accounts.get_user_by_api_key(api_key) do
      nil ->
        # API Key ไม่ถูกต้อง
        json(conn, %{status: "error", message: "Invalid API Key"})

      user ->
        # เช็คว่า User ยังมี following_id หรือไม่
        if user.following_id do
           # ยังตามอยู่ -> ส่ง active
           json(conn, %{status: "active", master_id: user.following_id})
        else
           # เลิกตามแล้ว (เป็น nil) -> ส่ง inactive
           json(conn, %{status: "inactive"})
        end
    end
  end
end
