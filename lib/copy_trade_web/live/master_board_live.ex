defmodule CopyTradeWeb.MasterBoardLive do
  use CopyTradeWeb, :live_view
  alias CopyTrade.Accounts

  def mount(_params, _session, socket) do
    masters = Accounts.list_masters_with_counts()
    {:ok, assign(socket, masters: masters)}
  end

  def render(assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-2xl font-bold mb-6">🏆 Top Masters</h1>
      <div class="grid gap-4">
        <%= for m <- @masters do %>
          <div class="bg-white p-4 rounded-lg shadow border flex justify-between items-center">
            <div>
              <h2 class="text-xl font-bold"><%= m.name %></h2>
              <p class="text-sm text-gray-500">Token: <span class="bg-gray-100 px-2 py-1 rounded select-all font-mono"><%= m.token %></span></p>
            </div>
            <div class="text-center">
              <span class="text-2xl font-bold text-indigo-600"><%= m.follower_count %></span>
              <p class="text-xs text-gray-400">Followers</p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
