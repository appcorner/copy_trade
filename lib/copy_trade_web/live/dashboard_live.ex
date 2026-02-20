defmodule CopyTradeWeb.DashboardLive do
  use CopyTradeWeb, :live_view

  alias CopyTrade.Accounts
  alias CopyTrade.TradePairContext
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CopyTrade.PubSub, "market_prices")
      Phoenix.PubSub.subscribe(CopyTrade.PubSub, "dashboard_notifications")
    end

    {:ok, assign(socket, prices: %{})}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    user = socket.assigns.current_scope.user
    account = Accounts.get_trading_account!(id)

    if account.user_id != user.id do
      {:noreply,
       socket
       |> put_flash(:error, "Unauthorized access")
       |> redirect(to: ~p"/accounts")}
    else
      if connected?(socket) do
        Phoenix.PubSub.subscribe(CopyTrade.PubSub, "trade_signals")
      end

      socket =
        socket
        |> assign(:current_account, account)
        |> assign(:page_title, "#{account.name} Dashboard")

      socket =
        if account.role == "master" do
          assign_master_data(socket, account)
        else
          assign_follower_data(socket, account)
        end

      {:noreply, socket}
    end
  end

  # เตรียมข้อมูลสำหรับ Master
  defp assign_master_data(socket, account) do
    # (ในอนาคต) ดึงจำนวนคนติดตามมาโชว์ตรงนี้
    follower_count =
      CopyTrade.Repo.aggregate(
        from(t in CopyTrade.Accounts.TradingAccount, where: t.following_id == ^account.id),
        :count
      )

    total_profit = Accounts.get_master_total_profit(account.id)
    chart_data = get_master_chart_data(account.id)

    socket
    |> assign(
      role: :master,
      page_title: "Master Dashboard - #{account.name}",
      api_key: account.api_key,
      master_token: account.master_token,
      follower_count: follower_count,
      master_total_profit: total_profit,
      chart_data: chart_data
    )
    |> push_chart_data(chart_data)
  end

  # ดึงข้อมูลกำไรสะสมของ Master จาก master_trades
  defp get_master_chart_data(master_account_id) do
    import Ecto.Query
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

  # เพิ่มการดึงข้อมูลเทรดในฟังก์ชันของ Follower
  defp assign_follower_data(socket, account) do
    current_master = Accounts.get_following_master(account.id)

    # 1. ดึงข้อมูล
    active_pairs = TradePairContext.list_active_pairs(account.id)
    closed_pairs = TradePairContext.list_closed_pairs(account.id)
    total_profit = TradePairContext.get_total_profit(account.id)
    chart_data = TradePairContext.get_cumulative_profit_data(account.id)

    socket
    |> assign(
      role: :follower,
      page_title: "Follower Dashboard - #{account.name}",
      api_key: account.api_key,
      current_master: current_master,
      # Assign data เข้าหน้าจอ
      active_pairs: active_pairs,
      closed_pairs: closed_pairs,
      total_profit: total_profit,
      chart_data: chart_data
    )
    |> push_chart_data(chart_data)
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
  def handle_info(%{event: "price_update", payload: payload}, socket) do
    # IO.inspect(payload, label: ">>> LIVEVIEW RECEIVED PRICE") # เพิ่มบรรทัดนี้
    # 1. ดึง Map ของราคาทั้งหมดที่มีอยู่ใน Socket ตอนนี้ (ถ้าไม่มีให้เป็น Map ว่าง)
    current_prices = socket.assigns.prices
    # IO.inspect(current_prices, label: ">>> current_prices")

    # 2. อัปเดตราคาสัญลักษณ์ที่เพิ่งส่งมาใหม่เข้าไปใน Map
    # เราใช้ Key เป็น {master_id, symbol} เพื่อให้ตรงกับโครงสร้างใน Context
    updated_prices = Map.put(current_prices, {payload.master_id, payload.symbol}, payload)
    # IO.inspect(updated_prices, label: ">>> updated_prices")

    # 3. Assign ค่ากลับลงใน Socket เพื่อให้ LiveView ทำการ Re-render ส่วนที่เกี่ยวข้อง
    {:noreply, assign(socket, :prices, updated_prices)}
  end

  def handle_info(%{event: "stop_out_detected"} = payload, socket) do
    # ใช้ put_flash ของ Phoenix เพื่อแสดง Toast มาตรฐาน
    # หรือส่ง push_event ไปหา JavaScript เพื่อทำ Toast สวยๆ เอง
    {:noreply,
     socket
     |> put_flash(:error, payload.message)
     |> push_event("play_alert_sound", %{type: "emergency"})}
  end

  @impl true
  def handle_info(%{event: "refresh"}, socket) do
    account = socket.assigns.current_account

    if socket.assigns.role == :master do
      chart_data = get_master_chart_data(account.id)

      follower_count =
        CopyTrade.Repo.aggregate(
          from(t in CopyTrade.Accounts.TradingAccount, where: t.following_id == ^account.id),
          :count
        )

      socket =
        socket
        |> assign(
          follower_count: follower_count,
          master_total_profit: Accounts.get_master_total_profit(account.id),
          chart_data: chart_data
        )
        |> push_chart_data(chart_data)

      {:noreply, socket}
    else
      chart_data = TradePairContext.get_cumulative_profit_data(account.id)

      socket =
        socket
        |> assign(
          active_pairs: TradePairContext.list_active_pairs(account.id),
          closed_pairs: TradePairContext.list_closed_pairs(account.id),
          total_profit: TradePairContext.get_total_profit(account.id),
          chart_data: chart_data
        )
        |> push_chart_data(chart_data)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # [NEW] รับ Event เมื่อกดปุ่ม Unfollow
  @impl true
  def handle_event("unfollow", _params, socket) do
    account = socket.assigns.current_account

    # 1. อัปเดต Database (เลิกติดตาม)
    case Accounts.unfollow_master(account.id) do
      {:ok, _updated_account} ->
        # 2. [สำคัญ] แจ้ง EA ผ่าน TCP ทันที (Push Notification)
        # ค้นหา Socket ของ Account นี้จาก Registry
        case Registry.lookup(CopyTrade.Registry, "account:#{account.id}") do
          [{pid, _}] ->
            # สั่งให้ Socket Handler ส่งข้อความ "CMD_STOP" ไปหา EA เดี๋ยวนี้
            # CopyTrade.SocketHandler.send_command(pid, "CMD_STOP")
            # Note: Assuming direct send is not available, we send a message that the handler understands
            send(pid, {:direct_signal, %{action: "CMD_STOP", reason: "unfollow"}})

          [] ->
            # EA ไม่ได้ต่ออยู่ ก็ไม่ต้องทำอะไร
            :ok
        end

        # 3. แจ้ง Worker ให้หยุด Logic ภายใน (ถ้ามี Worker แยก)
        # case Registry.lookup(CopyTrade.FollowerRegistry, account.id) do
        #   [{pid, _}] -> GenServer.cast(pid, {:update_master, nil})
        #   [] -> :ok
        # end

        {:noreply,
         socket
         |> put_flash(:info, "ยกเลิกการติดตามแล้ว! สั่ง EA ปิดการทำงานทันที")
         |> assign(:current_master, nil)
         # Reset หน้าจอ
         |> assign(:active_pairs, [])}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "เกิดข้อผิดพลาด")}
    end
  end

  def handle_event("change_mode", %{"mode" => mode}, socket) do
    account = socket.assigns.current_account

    case Accounts.update_copy_mode(account, mode) do
      {:ok, updated_account} ->
        mode_label =
          case mode do
            "PUBSUB" -> "📡 PUBSUB (ส่งสัญญาณให้ทุกคน)"
            "1TO1" -> "🤝 1TO1 (ส่งตรงถึงคู่แท้)"
            "RECORD" -> "📝 RECORD (บันทึกผลงานอย่างเดียว)"
            _ -> mode
          end

        {:noreply,
         socket
         |> assign(:current_account, updated_account)
         |> push_chart_data(socket.assigns.chart_data)
         |> put_flash(:info, "เปลี่ยนโหมดเป็น #{mode_label} แล้ว")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "ไม่สามารถเปลี่ยนโหมดได้")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-2">
      <%= if @role == :master do %>
        <div class="mb-8 flex items-center justify-between">
          <div>
            <.link
              navigate={~p"/accounts"}
              class="text-sm text-indigo-600 hover:text-indigo-800 font-medium mb-2 inline-block"
            >
              &larr; Back to Accounts
            </.link>
            <h1 class="text-3xl font-bold text-gray-900">🏆 {@current_account.name} (Master)</h1>
            
            <p class="text-gray-500">Managed by {@current_scope.user.name}</p>
          </div>
          
          <div class="text-right">
            <span class="block text-3xl font-bold text-indigo-600">{@follower_count}</span>
            <span class="text-xs text-gray-500 uppercase tracking-wide">ผู้ติดตาม</span>
          </div>
        </div>
        
        <div class="bg-white rounded-xl shadow-md border border-gray-200 p-6 mb-6">
          <h2 class="text-lg font-bold text-gray-800 mb-3">⚙️ โหมดการทำงาน</h2>
          
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <button
              phx-click="change_mode"
              phx-value-mode="PUBSUB"
              class={"rounded-xl border-2 p-4 text-center transition-all #{if @current_account.copy_mode == "PUBSUB", do: "border-indigo-600 bg-indigo-50", else: "border-gray-200 hover:border-gray-400"}"}
            >
              <div class="text-2xl mb-1">📡</div>
              
              <div class="font-bold text-sm text-gray-900">PUBSUB</div>
              
              <div class="text-xs text-gray-500 mt-1">ส่งสัญญาณให้ทุกคน</div>
            </button>
            <button
              phx-click="change_mode"
              phx-value-mode="1TO1"
              class={"rounded-xl border-2 p-4 text-center transition-all #{if @current_account.copy_mode == "1TO1", do: "border-indigo-600 bg-indigo-50", else: "border-gray-200 hover:border-gray-400"}"}
            >
              <div class="text-2xl mb-1">🤝</div>
              
              <div class="font-bold text-sm text-gray-900">1TO1</div>
              
              <div class="text-xs text-gray-500 mt-1">ส่งตรงถึงคู่แท้</div>
            </button>
            <button
              phx-click="change_mode"
              phx-value-mode="RECORD"
              class={"rounded-xl border-2 p-4 text-center transition-all #{if @current_account.copy_mode == "RECORD", do: "border-amber-500 bg-amber-50", else: "border-gray-200 hover:border-gray-400"}"}
            >
              <div class="text-2xl mb-1">📝</div>
              
              <div class="font-bold text-sm text-gray-900">RECORD</div>
              
              <div class="text-xs text-gray-500 mt-1">บันทึกผลงานอย่างเดียว</div>
            </button>
          </div>
          
          <%= if @current_account.copy_mode == "RECORD" do %>
            <div class="mt-3 flex items-center gap-2 bg-amber-50 border border-amber-200 rounded-lg p-3 text-sm text-amber-800">
              <span>⚠️</span>
              <span>
                โหมดบันทึกอย่างเดียว — ข้อมูลเทรดจะถูกบันทึกไว้ แต่ <strong>ไม่ส่งสัญญาณ</strong> ให้ Follower
              </span>
            </div>
          <% end %>
        </div>
        
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="bg-gradient-to-br from-indigo-600 to-indigo-800 rounded-xl shadow-lg p-6 text-white relative overflow-hidden">
            <div class="relative z-10">
              <h2 class="text-lg font-medium opacity-90 mb-1">Master Token ของคุณ</h2>
              
              <p class="text-xs opacity-70 mb-3">ส่งรหัสนี้ให้ผู้ติดตาม เพื่อใช้เชื่อมต่อกับคุณ</p>
              
              <div class="bg-white/20 backdrop-blur-sm rounded-lg p-3 font-mono text-base font-bold tracking-wider text-center border border-white/30 select-all">
                {@master_token}
              </div>
            </div>
            
            <div class="absolute -bottom-10 -right-10 w-40 h-40 bg-white/10 rounded-full blur-2xl">
            </div>
          </div>
          
          <div class="bg-white rounded-xl shadow-md border border-gray-200 p-6">
            <h2 class="text-lg font-bold text-gray-800 mb-2">📡 การเชื่อมต่อ EA</h2>
            
            <p class="text-sm text-gray-500 mb-4">API Key สำหรับ "MasterSenderTCP" EA</p>
            
            <div class="bg-gray-100 rounded-lg p-3 font-mono text-sm text-gray-700 break-all border border-gray-200 select-all">
              {@api_key}
            </div>
          </div>
        </div>
        
        <div
          class="mb-8 bg-white rounded-xl shadow-md border border-gray-200 p-6 mt-8"
          id="profit-chart-container"
          phx-hook="CumulativeProfitChart"
        >
          <div class="flex items-center justify-between mb-4">
            <div>
              <h3 class="text-lg font-bold text-gray-900 flex items-center gap-2">
                📈 กำไรสะสม (Cumulative Profit)
              </h3>
              
              <p class="text-sm text-gray-500">แสดงกำไรสะสมจากสัญญาณทั้งหมด</p>
            </div>
            
            <div class="text-right">
              <div class={"text-2xl font-bold #{if @master_total_profit >= 0, do: "text-green-600", else: "text-red-600"}"}>
                {if @master_total_profit > 0, do: "+", else: ""}{:erlang.float_to_binary(
                  @master_total_profit,
                  decimals: 2
                )} $
              </div>
              
              <div class="text-xs text-gray-400">{length(@chart_data)} signals</div>
            </div>
          </div>
          
          <div style="height: 300px; position: relative;">
            <canvas id="cumulative-profit-canvas"></canvas>
          </div>
          
          <%= if @chart_data == [] do %>
            <div class="flex items-center justify-center py-8">
              <p class="text-gray-400 text-sm">ยังไม่มีข้อมูลการเทรด</p>
            </div>
          <% end %>
        </div>
        
        <div class="p-6 bg-white border border-gray-200 rounded-xl shadow-sm">
          <h3 class="text-lg font-bold text-gray-800">Master Sender EA</h3>
          
          <p class="text-sm text-gray-500 mt-2">สำหรับบัญชี Master ที่ต้องการส่งสัญญาณ</p>
          
          <a
            href="/downloads/MasterSenderTCP_V7_0.ex5"
            class="inline-block mt-4 px-6 py-2 bg-indigo-600 text-white font-medium rounded-lg hover:bg-indigo-700 transition"
            download
          >
            📥 Download v7.0 (MQ5)
          </a>
        </div>
      <% else %>
        <div class="mb-8">
          <.link
            navigate={~p"/accounts"}
            class="text-sm text-indigo-600 hover:text-indigo-800 font-medium mb-2 inline-block"
          >
            &larr; Back to Accounts
          </.link>
          <h1 class="text-3xl font-bold text-gray-900">🚀 {@current_account.name}</h1>
          
          <p class="text-gray-500">Portfolio managed by {@current_scope.user.name}</p>
        </div>
        
        <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
          <div class="md:col-span-2 bg-white rounded-xl shadow-md border border-gray-200 p-6">
            <h2 class="text-xl font-bold text-gray-800 mb-4">🔌 สถานะการเชื่อมต่อ</h2>
            
            <%= if @current_master do %>
              <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-4 bg-green-50 border border-green-200 rounded-lg p-4">
                <div class="flex items-center">
                  <div class="h-12 w-12 rounded-full bg-green-100 flex items-center justify-center text-2xl mr-4 shrink-0">
                    🏆
                  </div>
                  
                  <div class="overflow-hidden">
                    <p class="text-sm text-green-800 font-bold">เชื่อมต่อกับ Master แล้ว</p>
                    
                    <p class="text-lg font-bold text-gray-900 truncate">{@current_master.name}</p>
                    
                    <p class="text-xs text-gray-500 truncate">{@current_master.master_token}</p>
                  </div>
                </div>
                
                <button
                  phx-click="unfollow"
                  data-confirm="ยืนยันการเลิกติดตาม?"
                  class="w-full sm:w-auto bg-white text-red-600 hover:text-red-700 border border-red-200 text-xs font-bold py-2 px-4 rounded shadow-sm transition-colors shrink-0"
                >
                  Unfollow
                </button>
              </div>
            <% else %>
              <div class="flex items-center bg-yellow-50 border border-yellow-200 rounded-lg p-4 mb-4">
                <div class="text-2xl mr-4">⚠️</div>
                
                <div>
                  <p class="text-sm text-yellow-800 font-bold">ยังไม่ได้เชื่อมต่อ</p>
                  
                  <p class="text-xs text-gray-600">คุณยังไม่มี Master ที่ติดตาม</p>
                </div>
              </div>
              
              <.link
                navigate="/masters"
                class="inline-flex items-center justify-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm w-full"
              >
                🔍 ค้นหาผู้นำเทรด
              </.link>
            <% end %>
          </div>
          
          <div class="bg-indigo-600 rounded-xl p-6 text-white shadow-lg flex flex-col justify-center">
            <div class="text-indigo-200 text-sm font-medium uppercase tracking-wider mb-1">
              กำไรรวม (Total Profit)
            </div>
            
            <div class="text-4xl font-bold">
              $ {:erlang.float_to_binary(@total_profit, decimals: 2)}
            </div>
            
            <div class="mt-2 text-xs text-indigo-300">
              อัปเดตล่าสุด: {format_bkk(DateTime.utc_now(), "%H:%M")}
            </div>
          </div>
        </div>
        
        <div
          class="mb-8 bg-white rounded-xl shadow-md border border-gray-200 p-6"
          id="profit-chart-container"
          phx-hook="CumulativeProfitChart"
        >
          <div class="flex items-center justify-between mb-4">
            <div>
              <h3 class="text-lg font-bold text-gray-900 flex items-center gap-2">
                📈 กำไรสะสม (Cumulative Profit)
              </h3>
              
              <p class="text-sm text-gray-500">แสดงกำไรสะสมจากการเทรดทั้งหมด</p>
            </div>
            
            <div class="text-right">
              <div class={"text-2xl font-bold #{if @total_profit >= 0, do: "text-green-600", else: "text-red-600"}"}>
                {if @total_profit > 0, do: "+", else: ""}{:erlang.float_to_binary(@total_profit,
                  decimals: 2
                )} $
              </div>
              
              <div class="text-xs text-gray-400">{length(@chart_data)} trades</div>
            </div>
          </div>
          
          <div style="height: 300px; position: relative;">
            <canvas id="cumulative-profit-canvas"></canvas>
          </div>
          
          <%= if @chart_data == [] do %>
            <div class="absolute inset-0 flex items-center justify-center">
              <p class="text-gray-400 text-sm">ยังไม่มีข้อมูลการเทรด</p>
            </div>
          <% end %>
        </div>
        
        <div class="mb-12">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-lg font-bold text-gray-900 flex items-center gap-2">
              ⚡ ออเดอร์ที่ถืออยู่ (Active Trades)
              <span class="inline-flex items-center rounded-md bg-green-50 px-2 py-1 text-xs font-medium text-green-700 ring-1 ring-inset ring-green-600/20 animate-pulse">
                Live
              </span>
            </h3>
          </div>
          
          <div class="bg-white shadow-sm ring-1 ring-gray-900/5 sm:rounded-xl overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-300">
              <thead class="bg-gray-50">
                <tr>
                  <th class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900">
                    Symbol
                  </th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Type</th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">
                    Lot (M → S)
                  </th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">
                    Price / SL-TP
                  </th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Status</th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Time</th>
                  
                  <th class="px-3 py-3.5 text-right text-sm font-semibold text-gray-900">
                    Profit ($)
                  </th>
                </tr>
              </thead>
              
              <tbody class="divide-y divide-gray-200 bg-white">
                <%= for pair <- @active_pairs do %>
                  <tr class="hover:bg-gray-50 transition">
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm">
                      <div class="font-bold text-gray-900">{pair.master_trade.symbol}</div>
                      
                      <div class="text-xs text-gray-500">#{pair.slave_ticket}</div>
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm">
                      <div class="flex items-center gap-2">
                        <span class={"font-bold text-xs " <> if(pair.master_trade.type == "BUY", do: "text-green-600", else: "text-red-600")}>
                          M: {pair.master_trade.type}
                        </span> <span class="text-gray-400">→</span>
                        <%= if pair.slave_type do %>
                          <span class={
                            "inline-flex items-center rounded-md px-2 py-1 text-xs font-bold ring-1 ring-inset " <>
                            if(pair.slave_type == "BUY",
                              do: "bg-green-100 text-green-700 ring-green-600/20",
                              else: "bg-red-100 text-red-700 ring-red-600/20")
                          }>
                            {pair.slave_type}
                          </span>
                        <% else %>
                          <span class="text-gray-400 text-xs">Waiting...</span>
                        <% end %>
                      </div>
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                      <div class="flex items-center gap-1">
                        <span class="text-gray-400">{pair.master_trade.volume || "-"}</span>
                        <svg
                          class="w-3 h-3 text-gray-300"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M17 8l4 4m0 0l-4 4m4-4H3"
                          >
                          </path>
                        </svg>
                        <span class="font-bold text-gray-900">{pair.slave_volume || "..."}</span>
                      </div>
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm">
                      <div class="font-medium text-gray-900">{pair.open_price}</div>
                      
                      <div class="text-xs flex gap-2 mt-0.5">
                        <%= if pair.master_trade.sl && pair.master_trade.sl > 0 do %>
                          <span class="text-red-600 font-medium">SL: {pair.master_trade.sl}</span>
                        <% end %>
                        
                        <%= if pair.master_trade.tp && pair.master_trade.tp > 0 do %>
                          <span class="text-green-600 font-medium">TP: {pair.master_trade.tp}</span>
                        <% end %>
                      </div>
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm">
                      <span class={"inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium #{if pair.status == "OPEN", do: "bg-blue-50 text-blue-700", else: "bg-gray-100 text-gray-600"}"}>
                        {pair.status}
                      </span>
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-400">
                      {format_bkk(pair.inserted_at, "%H:%M:%S")}
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-right font-mono font-bold">
                      <%!-- เรียกใช้ Context ที่เราเตรียมไว้เพื่อคำนวณกำไรสดๆ --%> <% floating_pl =
                        TradePairContext.calculate_floating_profit(pair, @prices) %>
                      <span class={if floating_pl >= 0, do: "text-green-600", else: "text-red-600"}>
                        {if floating_pl > 0, do: "+", else: ""}{:erlang.float_to_binary(floating_pl,
                          decimals: 2
                        )} $
                      </span>
                    </td>
                  </tr>
                <% end %>
                
                <%= if @active_pairs == [] do %>
                  <tr>
                    <td colspan="6" class="text-center py-8 text-gray-400">ไม่มีออเดอร์ที่ถืออยู่</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
        
        <div class="mb-8">
          <h3 class="text-lg font-bold text-gray-900 mb-4">📜 ประวัติการเทรดล่าสุด</h3>
          
          <div class="bg-white shadow-sm ring-1 ring-gray-900/5 sm:rounded-xl overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-300">
              <thead class="bg-gray-50">
                <tr>
                  <th class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900">
                    Symbol
                  </th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Type</th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">
                    Open Price
                  </th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">
                    Close Price
                  </th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Lot</th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Profit</th>
                  
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Time</th>
                </tr>
              </thead>
              
              <tbody class="divide-y divide-gray-200 bg-white">
                <%= for pair <- @closed_pairs do %>
                  <tr>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900">
                      {pair.master_trade.symbol}
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm">
                      <span class={"text-xs font-bold #{if pair.master_trade.type == "BUY", do: "text-green-600", else: "text-red-600"}"}>
                        {pair.master_trade.type}
                      </span>
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                      {pair.open_price}
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                      {pair.close_price}
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                      {pair.slave_volume}
                    </td>
                    
                    <td class={"whitespace-nowrap px-3 py-4 text-sm font-bold #{if pair.profit >= 0, do: "text-green-600", else: "text-red-600"}"}>
                      {if pair.profit > 0, do: "+", else: ""}{pair.profit} $
                    </td>
                    
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                      {format_bkk(pair.updated_at, "%d/%m %H:%M")}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
        
        <div class="p-6 bg-white border border-gray-200 rounded-xl shadow-sm">
          <h3 class="text-lg font-bold text-gray-800">Slave Copy EA</h3>
          
          <p class="text-sm text-gray-500 mt-2">สำหรับบัญชี Follower ที่ต้องการคัดลอกไม้</p>
          
          <a
            href="/downloads/SlaveTCP_V7_0.ex5"
            class="inline-block mt-4 px-6 py-2 bg-green-600 text-white font-medium rounded-lg hover:bg-green-700 transition"
            download
          >
            📥 Download v7.0 (MQ5)
          </a>
        </div>
      <% end %>
    </div>
    """
  end

  # ฟังก์ชันแปลงเวลาเป็น Bangkok (UTC+7)
  defp format_bkk(nil, _fmt), do: "-"

  defp format_bkk(dt, format) do
    dt
    # เช็คว่าเป็น DateTime หรือ NaiveDateTime แล้วบวก 7 ชม.
    |> case do
      %DateTime{} -> DateTime.add(dt, 7, :hour)
      %NaiveDateTime{} -> NaiveDateTime.add(dt, 7, :hour)
      _ -> dt
    end
    |> Calendar.strftime(format)
  end
end
