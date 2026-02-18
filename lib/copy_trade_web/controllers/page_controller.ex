defmodule CopyTradeWeb.PageController do
  use CopyTradeWeb, :controller

  def home(conn, _params) do
    conn
    |> put_root_layout(html: {CopyTradeWeb.Layouts, :root})
    |> render(:home)
  end
end
