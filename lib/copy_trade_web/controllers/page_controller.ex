defmodule CopyTradeWeb.PageController do
  use CopyTradeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
