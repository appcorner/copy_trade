defmodule CopyTradeWeb.MasterProfileLive do
  use CopyTradeWeb, :live_view

  alias CopyTrade.Accounts
  alias CopyTrade.Accounts.TradingAccount
  import Ecto.Query

  @impl true
  def mount(%{"master_token" => token}, _session, socket) do
    case Accounts.get_master_account_by_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "ไม่พบ Master ที่ต้องการ")
         |> redirect(to: ~p"/top-masters")}

      %TradingAccount{} = master ->
        # ดึงข้อมูลสถิติ
        total_profit = Accounts.get_master_total_profit(master.id)
        chart_data = get_master_chart_data(master.id)
        stats = get_master_stats(master.id)

        follower_count =
          CopyTrade.Repo.aggregate(
            from(t in TradingAccount, where: t.following_id == ^master.id),
            :count
          )

        {:ok,
         socket
         |> assign(
           master: master,
           master_token: token,
           total_profit: total_profit,
           chart_data: chart_data,
           follower_count: follower_count,
           stats: stats,
           page_title: "#{master.name} — Master Profile"
         )
         |> push_chart_data(chart_data)}
    end
  end

  # ดึง chart data ของ Master
  defp get_master_chart_data(master_account_id) do
    alias CopyTrade.MasterTrade
    alias CopyTrade.Repo

    from(mt in MasterTrade,
      where: mt.master_id == ^master_account_id and mt.status == "CLOSED",
      order_by: [asc: mt.updated_at],
      select: %{profit: mt.profit, closed_at: mt.updated_at}
    )
    |> Repo.all()
    |> Enum.reduce({[], 0.0}, fn trade, {acc, running_total} ->
      new_total = running_total + (trade.profit || 0.0)

      date_str =
        if trade.closed_at, do: Calendar.strftime(trade.closed_at, "%d/%m %H:%M"), else: "N/A"

      {acc ++
         [
           %{
             date: date_str,
             cumulative_profit: Float.round(new_total, 2),
             profit: Float.round(trade.profit || 0.0, 2)
           }
         ], new_total}
    end)
    |> elem(0)
  end

  # สถิติเพิ่มเติมของ Master
  defp get_master_stats(master_account_id) do
    alias CopyTrade.MasterTrade
    alias CopyTrade.Repo

    closed_trades =
      from(mt in MasterTrade,
        where: mt.master_id == ^master_account_id and mt.status == "CLOSED"
      )
      |> Repo.all()

    total_trades = length(closed_trades)
    winning_trades = Enum.count(closed_trades, fn t -> (t.profit || 0.0) > 0 end)
    losing_trades = Enum.count(closed_trades, fn t -> (t.profit || 0.0) < 0 end)

    win_rate =
      if total_trades > 0,
        do: Float.round(winning_trades / total_trades * 100, 1),
        else: 0.0

    best_trade =
      closed_trades
      |> Enum.map(& &1.profit)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> 0.0
        profits -> Enum.max(profits)
      end

    worst_trade =
      closed_trades
      |> Enum.map(& &1.profit)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> 0.0
        profits -> Enum.min(profits)
      end

    avg_profit =
      if total_trades > 0 do
        total = Enum.reduce(closed_trades, 0.0, fn t, acc -> acc + (t.profit || 0.0) end)
        Float.round(total / total_trades, 2)
      else
        0.0
      end

    # คำนวณ Max Drawdown
    max_drawdown = calculate_max_drawdown(closed_trades)

    %{
      total_trades: total_trades,
      winning_trades: winning_trades,
      losing_trades: losing_trades,
      win_rate: win_rate,
      best_trade: best_trade,
      worst_trade: worst_trade,
      avg_profit: avg_profit,
      max_drawdown: max_drawdown
    }
  end

  defp calculate_max_drawdown(trades) do
    trades
    |> Enum.reduce({0.0, 0.0, 0.0}, fn trade, {peak, max_dd, cum} ->
      new_cum = cum + (trade.profit || 0.0)
      new_peak = max(peak, new_cum)
      drawdown = new_peak - new_cum
      new_max_dd = max(max_dd, drawdown)
      {new_peak, new_max_dd, new_cum}
    end)
    |> elem(1)
    |> Float.round(2)
  end

  defp push_chart_data(socket, chart_data) do
    labels = Enum.map(chart_data, & &1.date)
    values = Enum.map(chart_data, & &1.cumulative_profit)
    profits = Enum.map(chart_data, & &1.profit)

    push_event(socket, "chart_data", %{
      labels: labels,
      values: values,
      profits: profits
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={assigns[:current_scope]}>
      <div class="max-w-4xl mx-auto py-2">
        <%!-- Back link --%>
        <.link
          navigate={~p"/top-masters"}
          class="inline-flex items-center gap-1 text-sm text-indigo-600 hover:text-indigo-800 font-medium mb-6 group"
        >
          <svg
            class="w-4 h-4 transition-transform group-hover:-translate-x-0.5"
            fill="none"
            viewBox="0 0 24 24"
            stroke-width="2"
            stroke="currentColor"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
          </svg>
          กลับไปหน้า Top Masters
        </.link> <%!-- Master Header Card --%>
        <div class="relative overflow-hidden bg-gradient-to-br from-indigo-600 via-indigo-700 to-purple-800 rounded-2xl shadow-xl p-6 mb-5">
          <div class="absolute top-0 right-0 w-64 h-64 bg-white/5 rounded-full -translate-y-32 translate-x-32 blur-2xl">
          </div>

          <div class="absolute bottom-0 left-0 w-48 h-48 bg-white/5 rounded-full translate-y-24 -translate-x-24 blur-2xl">
          </div>

          <div class="relative z-10">
            <div class="flex items-center gap-5 mb-4">
              <div class="w-16 h-16 rounded-2xl bg-white/20 backdrop-blur-sm flex items-center justify-center text-4xl border border-white/20 shadow-lg">
                🏆
              </div>

              <div>
                <h1 class="text-3xl font-bold text-white tracking-tight">{@master.name}</h1>

                <p class="text-indigo-200 text-sm mt-1 flex items-center gap-2">
                  <span class="inline-flex items-center rounded-full bg-white/20 px-2.5 py-0.5 text-xs font-semibold text-white backdrop-blur-sm">
                    Master Trader
                  </span> <span class="text-indigo-300/80">·</span>
                  <span class="text-indigo-200/80">{@follower_count} ผู้ติดตาม</span>
                </p>
              </div>
            </div>

            <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
              <div class="bg-white/10 backdrop-blur-sm rounded-xl p-3 border border-white/10">
                <div class="text-xs text-indigo-200 uppercase tracking-wide font-semibold mb-1">
                  Total Profit
                </div>

                <div class={[
                  "text-2xl font-bold",
                  if(@total_profit >= 0, do: "text-emerald-300", else: "text-red-300")
                ]}>
                  {if @total_profit > 0, do: "+", else: ""}{:erlang.float_to_binary(
                    @total_profit,
                    decimals: 2
                  )} $
                </div>
              </div>

              <div class="bg-white/10 backdrop-blur-sm rounded-xl p-3 border border-white/10">
                <div class="text-xs text-indigo-200 uppercase tracking-wide font-semibold mb-1">
                  Win Rate
                </div>

                <div class="text-2xl font-bold text-white">{@stats.win_rate}%</div>
              </div>

              <div class="bg-white/10 backdrop-blur-sm rounded-xl p-3 border border-white/10">
                <div class="text-xs text-indigo-200 uppercase tracking-wide font-semibold mb-1">
                  Total Trades
                </div>

                <div class="text-2xl font-bold text-white">{@stats.total_trades}</div>
              </div>

              <div class="bg-white/10 backdrop-blur-sm rounded-xl p-3 border border-white/10">
                <div class="text-xs text-indigo-200 uppercase tracking-wide font-semibold mb-1">
                  ผู้ติดตาม
                </div>

                <div class="text-2xl font-bold text-white">{@follower_count}</div>
              </div>
            </div>
          </div>
        </div>
         <%!-- Share Link Bar --%>
        <div
          class="mb-4 bg-white rounded-xl shadow-sm border border-gray-200 p-3 flex items-center gap-3"
          id="share-link-bar"
        >
          <div class="flex-shrink-0">
            <div class="w-10 h-10 bg-indigo-100 rounded-lg flex items-center justify-center">
              <svg
                class="w-5 h-5 text-indigo-600"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="2"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M13.19 8.688a4.5 4.5 0 011.242 7.244l-4.5 4.5a4.5 4.5 0 01-6.364-6.364l1.757-1.757m9.686-5.654a4.5 4.5 0 00-1.242-7.244l-4.5-4.5a4.5 4.5 0 00-6.364 6.364l-1.757 1.757"
                />
              </svg>
            </div>
          </div>

          <div class="flex-1 min-w-0">
            <p class="text-xs text-gray-500 mb-0.5 font-medium">แชร์ลิงก์โปรไฟล์นี้</p>

            <div class="text-sm font-mono text-gray-700 truncate bg-gray-50 rounded px-2 py-1 border border-gray-100">
              /m/{@master_token}
            </div>
          </div>

          <button
            id="copy-share-link-btn"
            phx-hook="CopyToClipboard"
            data-copy-text={"/m/#{@master_token}"}
            class="flex-shrink-0 px-4 py-2 bg-indigo-600 text-white text-sm font-medium rounded-lg hover:bg-indigo-700 active:scale-95 transition-all shadow-sm"
          >
            📋 Copy Link
          </button>
        </div>
         <%!-- Statistics Cards --%>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-5">
          <div class="bg-white rounded-xl shadow-sm border border-gray-200 p-3 hover:shadow-md transition-shadow">
            <div class="text-xs text-gray-400 uppercase tracking-wide font-semibold mb-2">
              Best Trade
            </div>

            <div class="text-xl font-bold text-emerald-600">
              +{:erlang.float_to_binary(@stats.best_trade, decimals: 2)} $
            </div>
          </div>

          <div class="bg-white rounded-xl shadow-sm border border-gray-200 p-3 hover:shadow-md transition-shadow">
            <div class="text-xs text-gray-400 uppercase tracking-wide font-semibold mb-2">
              Worst Trade
            </div>

            <div class="text-xl font-bold text-red-600">
              {:erlang.float_to_binary(@stats.worst_trade, decimals: 2)} $
            </div>
          </div>

          <div class="bg-white rounded-xl shadow-sm border border-gray-200 p-3 hover:shadow-md transition-shadow">
            <div class="text-xs text-gray-400 uppercase tracking-wide font-semibold mb-2">
              Avg Profit
            </div>

            <div class={[
              "text-xl font-bold",
              if(@stats.avg_profit >= 0, do: "text-emerald-600", else: "text-red-600")
            ]}>
              {if @stats.avg_profit > 0, do: "+", else: ""}{:erlang.float_to_binary(
                @stats.avg_profit,
                decimals: 2
              )} $
            </div>
          </div>

          <div class="bg-white rounded-xl shadow-sm border border-gray-200 p-3 hover:shadow-md transition-shadow">
            <div class="text-xs text-gray-400 uppercase tracking-wide font-semibold mb-2">
              Max Drawdown
            </div>

            <div class="text-xl font-bold text-amber-600">
              -{:erlang.float_to_binary(@stats.max_drawdown, decimals: 2)} $
            </div>
          </div>
        </div>
         <%!-- Win/Loss Bar --%>
        <div class="bg-white rounded-xl shadow-sm border border-gray-200 p-5 mb-5">
          <div class="flex items-center justify-between mb-3">
            <h3 class="text-sm font-bold text-gray-700 uppercase tracking-wide">สถิติ Win / Loss</h3>

            <span class="text-sm text-gray-500">
              {if @stats.win_rate >= 60, do: "🔥", else: "📊"} {@stats.win_rate}% Win Rate
            </span>
          </div>

          <div class="flex rounded-full overflow-hidden h-4 bg-gray-100">
            <%= if @stats.total_trades > 0 do %>
              <div
                class="bg-emerald-500 transition-all duration-500"
                style={"width: #{@stats.win_rate}%"}
                title={"Won: #{@stats.winning_trades}"}
              >
              </div>

              <div
                class="bg-red-400 transition-all duration-500"
                style={"width: #{100 - @stats.win_rate}%"}
                title={"Lost: #{@stats.losing_trades}"}
              >
              </div>
            <% end %>
          </div>

          <div class="flex justify-between mt-2 text-xs text-gray-500">
            <span class="flex items-center gap-1">
              <span class="w-2 h-2 rounded-full bg-emerald-500 inline-block"></span>
              Win: {@stats.winning_trades}
            </span>
            <span class="flex items-center gap-1">
              <span class="w-2 h-2 rounded-full bg-red-400 inline-block"></span>
              Loss: {@stats.losing_trades}
            </span>
          </div>
        </div>
         <%!-- Profit Chart --%>
        <div
          class="bg-white rounded-xl shadow-sm border border-gray-200 p-5 mb-5"
          id="profit-chart-container"
          phx-hook="CumulativeProfitChart"
        >
          <div class="flex items-center justify-between mb-4">
            <div>
              <h3 class="text-lg font-bold text-gray-900 flex items-center gap-2">
                📈 กำไรสะสม (Cumulative Profit)
              </h3>

              <p class="text-sm text-gray-500">ข้อมูลจากการเทรดจริงทั้งหมด {@stats.total_trades} รายการ</p>
            </div>

            <div class="text-right">
              <div class={[
                "text-2xl font-bold",
                if(@total_profit >= 0, do: "text-green-600", else: "text-red-600")
              ]}>
                {if @total_profit > 0, do: "+", else: ""}{:erlang.float_to_binary(
                  @total_profit,
                  decimals: 2
                )} $
              </div>

              <div class="text-xs text-gray-400">{length(@chart_data)} signals</div>
            </div>
          </div>

          <div style="height: 320px; position: relative;">
            <canvas id="cumulative-profit-canvas"></canvas>
          </div>

          <%= if @chart_data == [] do %>
            <div class="flex items-center justify-center py-8">
              <div class="text-center">
                <div class="text-4xl mb-2">📭</div>

                <p class="text-gray-400 text-sm">ยังไม่มีข้อมูลการเทรด</p>
              </div>
            </div>
          <% end %>
        </div>
         <%!-- Disclaimer --%>
        <div class="text-center text-xs text-gray-400 mt-5 mb-2">
          <p>⚠️ ผลกำไรในอดีตไม่ได้รับประกันผลในอนาคต · ข้อมูลนี้เป็นเพียงการแสดงสถิติเท่านั้น</p>

          <p class="mt-1">Powered by <span class="font-bold text-indigo-500">⚡ CopyTradePro</span></p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
