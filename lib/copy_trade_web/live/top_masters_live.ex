defmodule CopyTradeWeb.TopMastersLive do
  use CopyTradeWeb, :live_view

  alias CopyTrade.Accounts

  @impl true
  def mount(_params, _session, socket) do
    masters =
      Accounts.list_masters_with_counts()
      |> Enum.map(fn m ->
        Map.put(m, :total_profit, Accounts.get_master_total_profit(m.master_id))
      end)
      |> Enum.sort_by(& &1.total_profit, :desc)

    {:ok,
     assign(socket,
       masters: masters,
       page_title: "Top Masters — CopyTradePro"
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={assigns[:current_scope]}>
      <div class="max-w-4xl mx-auto py-2">
        <%!-- Hero Header --%>
        <div class="text-center mb-6">
          <h1 class="text-4xl font-bold text-gray-900 tracking-tight mb-2">🏆 ทำเนียบผู้นำเทรด</h1>

          <p class="text-gray-500 text-lg max-w-2xl mx-auto">
            รวมผลงานจากผู้นำเทรดทุกคนในระบบ <span class="text-indigo-600 font-medium">CopyTradePro</span>
            กดดูรายละเอียดผลกำไรของแต่ละคนได้
          </p>
        </div>
         <%!-- Masters Grid --%>
        <div class="space-y-3">
          <%= for {m, idx} <- Enum.with_index(@masters) do %>
            <.link
              navigate={~p"/m/#{m.token}"}
              class="block group"
              id={"master-card-#{m.master_id}"}
            >
              <div class={[
                "relative overflow-hidden bg-white p-5 rounded-xl shadow-sm border transition-all duration-300 hover:shadow-lg hover:-translate-y-0.5",
                if(idx == 0 && m.total_profit > 0,
                  do: "border-amber-300 ring-1 ring-amber-200",
                  else: "border-gray-200 hover:border-indigo-300"
                )
              ]}>
                <%!-- Rank badge for top 3 --%>
                <%= cond do %>
                  <% idx == 0 -> %>
                    <div class="absolute top-0 right-0 bg-gradient-to-br from-amber-400 to-amber-500 text-white text-xs font-bold px-3 py-1 rounded-bl-xl shadow-sm">
                      🥇 #1
                    </div>
                  <% idx == 1 -> %>
                    <div class="absolute top-0 right-0 bg-gradient-to-br from-gray-300 to-gray-400 text-white text-xs font-bold px-3 py-1 rounded-bl-xl shadow-sm">
                      🥈 #2
                    </div>
                  <% idx == 2 -> %>
                    <div class="absolute top-0 right-0 bg-gradient-to-br from-amber-600 to-amber-700 text-white text-xs font-bold px-3 py-1 rounded-bl-xl shadow-sm">
                      🥉 #3
                    </div>
                  <% true -> %>
                    <div class="absolute top-0 right-0 bg-gray-100 text-gray-500 text-xs font-bold px-3 py-1 rounded-bl-xl">
                      #{idx + 1}
                    </div>
                <% end %>

                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-4">
                    <div class={[
                      "w-12 h-12 rounded-xl flex items-center justify-center text-2xl shadow-sm border",
                      if(idx == 0 && m.total_profit > 0,
                        do: "bg-gradient-to-br from-amber-50 to-amber-100 border-amber-200",
                        else: "bg-gradient-to-br from-indigo-50 to-indigo-100 border-indigo-200"
                      )
                    ]}>
                      🏆
                    </div>

                    <div>
                      <h2 class="text-lg font-bold text-gray-800 group-hover:text-indigo-600 transition-colors">
                        {m.name}
                      </h2>

                      <div class="flex items-center gap-3 mt-0.5">
                        <span class="text-xs text-gray-400 flex items-center gap-1">
                          <svg
                            class="w-3 h-3"
                            fill="none"
                            viewBox="0 0 24 24"
                            stroke-width="2"
                            stroke="currentColor"
                          >
                            <path
                              stroke-linecap="round"
                              stroke-linejoin="round"
                              d="M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 018.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0111.964-3.07M12 6.375a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zm8.25 2.25a2.625 2.625 0 11-5.25 0 2.625 2.625 0 015.25 0z"
                            />
                          </svg> {m.follower_count} ผู้ติดตาม
                        </span>
                      </div>
                    </div>
                  </div>

                  <div class="flex items-center gap-6">
                    <div class="text-right">
                      <p class="text-xs text-gray-400 uppercase font-bold tracking-wide">
                        Total Profit
                      </p>

                      <span class={[
                        "text-2xl font-bold",
                        if(m.total_profit >= 0, do: "text-emerald-600", else: "text-red-600")
                      ]}>
                        {if m.total_profit > 0, do: "+", else: ""}{:erlang.float_to_binary(
                          m.total_profit,
                          decimals: 2
                        )} $
                      </span>
                    </div>

                    <div class="text-gray-300 group-hover:text-indigo-400 transition-colors">
                      <svg
                        class="w-5 h-5"
                        fill="none"
                        viewBox="0 0 24 24"
                        stroke-width="2"
                        stroke="currentColor"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          d="M8.25 4.5l7.5 7.5-7.5 7.5"
                        />
                      </svg>
                    </div>
                  </div>
                </div>
              </div>
            </.link>
          <% end %>

          <%= if @masters == [] do %>
            <div class="text-center py-16">
              <div class="text-5xl mb-4">🔍</div>

              <p class="text-gray-400 text-lg">ยังไม่มี Master ในระบบ</p>

              <p class="text-gray-400 text-sm mt-1">ลองกลับมาดูใหม่ภายหลังนะครับ</p>
            </div>
          <% end %>
        </div>
         <%!-- Footer --%>
        <div class="text-center text-xs text-gray-400 mt-6 mb-2">
          <p>⚠️ ผลกำไรในอดีตไม่ได้รับประกันผลในอนาคต · ข้อมูลนี้เป็นเพียงการแสดงสถิติเท่านั้น</p>

          <p class="mt-1">Powered by <span class="font-bold text-indigo-500">⚡ CopyTradePro</span></p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
