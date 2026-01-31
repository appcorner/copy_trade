defmodule CopyTradeWeb.MasterBoardLive do
  use CopyTradeWeb, :live_view
  alias CopyTrade.Accounts

  def mount(_params, _session, socket) do
    # ดึงรายชื่อ Master พร้อมคำนวณกำไรรวม และเรียงลำดับจากมากไปน้อย
    masters =
      Accounts.list_masters_with_counts()
      |> Enum.map(fn m ->
        # สมมติว่าเรามีฟังก์ชัน get_master_total_profit ใน Accounts context
        Map.put(m, :total_profit, Accounts.get_master_total_profit(m.master_id))
      end)
      |> Enum.sort_by(& &1.total_profit, :desc) # เรียงลำดับกำไรสูงสุดไว้ด้านบน

    {:ok, assign(socket, masters: masters, page_title: "ทำเนียบผู้นำเทรด (Top Masters)")}
  end

  def render(assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-2xl font-bold mb-6 text-gray-900">🏆 ทำเนียบผู้นำเทรด (Top Masters)</h1>
      <div class="grid gap-4">
        <%= for m <- @masters do %>
          <div class="bg-white p-4 rounded-lg shadow border flex justify-between items-center hover:border-indigo-300 transition-colors">
            <div>
              <h2 class="text-xl font-bold text-gray-800"><%= m.name %></h2>
              <p class="text-sm text-gray-500">Token: <span class="bg-gray-100 px-2 py-1 rounded font-mono"><%= m.token %></span></p>
            </div>

            <div class="flex items-center space-x-8">
              <div class="text-right">
                <p class="text-xs text-gray-400 uppercase font-bold">Total Profit</p>
                <span class={"text-2xl font-bold #{if m.total_profit >= 0, do: "text-green-600", else: "text-red-600"}"}>
                  <%= if m.total_profit > 0, do: "+", else: "" %><%= :erlang.float_to_binary(m.total_profit, [decimals: 2]) %> $
                </span>
              </div>

              <div class="text-center border-l pl-8">
                <span class="text-2xl font-bold text-indigo-600"><%= m.follower_count %></span>
                <p class="text-xs text-gray-400">ผู้ติดตาม</p>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
