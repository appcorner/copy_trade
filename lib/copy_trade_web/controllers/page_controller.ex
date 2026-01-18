defmodule CopyTradeWeb.PageController do
  use CopyTradeWeb, :controller

  def home(conn, _params) do
    # เช็คว่ามี User ใน session ไหม
    if conn.assigns[:current_scope] do
      # ถ้ามี -> เด้งไป Dashboard เลย
      redirect(conn, to: ~p"/dashboard")
    else
      # ถ้าไม่มี -> โชว์หน้า Landing Page ปกติ
      render(conn, :home)
    end
  end
end
