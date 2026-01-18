defmodule CopyTradeWeb.DashboardLive do
  use CopyTradeWeb, :live_view

  on_mount {CopyTradeWeb.UserAuth, :require_sudo_mode}

  alias CopyTrade.Accounts
  alias CopyTrade.TradePairContext

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    socket =
      if user.role == "master" do
        assign_master_data(socket, user)
      else
        assign_follower_data(socket, user)
      end

    {:ok, socket}
  end

  # เตรียมข้อมูลสำหรับ Master
  defp assign_master_data(socket, user) do
    # (ในอนาคต) ดึงจำนวนคนติดตามมาโชว์ตรงนี้
    follower_count = 0

    assign(socket,
      role: :master,
      page_title: "Master Dashboard",
      api_key: user.api_key,
      master_token: user.master_token,
      follower_count: follower_count
    )
  end

  # เพิ่มการดึงข้อมูลเทรดในฟังก์ชันของ Follower
  defp assign_follower_data(socket, user) do
    current_master = Accounts.get_following_master(user)

    # 1. ดึงข้อมูล
    active_pairs = TradePairContext.list_active_pairs(user.id)
    closed_pairs = TradePairContext.list_closed_pairs(user.id)
    total_profit = TradePairContext.get_total_profit(user.id)

    # 2. Subscribe PubSub เพื่อให้หน้าจอขยับเองเมื่อมี Signal
    if connected?(socket), do: Phoenix.PubSub.subscribe(CopyTrade.PubSub, "trade_signals")

    assign(socket,
      role: :follower,
      page_title: "My Portfolio",
      api_key: user.api_key,
      current_master: current_master,
      # Assign data เข้าหน้าจอ
      active_pairs: active_pairs,
      closed_pairs: closed_pairs,
      total_profit: total_profit
    )
  end

  # 🔥 เพิ่ม handle_info เพื่อรับ Signal แล้ว Refresh ข้อมูลเอง
  @impl true
  def handle_info(_msg, socket) do
     # เมื่อมี Signal เข้ามา (ไม่ว่าจะ Open หรือ Close) ให้ดึงข้อมูลใหม่
     user = socket.assigns.current_user

     socket = assign(socket,
       active_pairs: TradePairContext.list_active_pairs(user.id),
       closed_pairs: TradePairContext.list_closed_pairs(user.id),
       total_profit: TradePairContext.get_total_profit(user.id)
     )
     {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4">

      <%= if @role == :master do %>
        <div class="mb-8 flex items-center justify-between">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">🏆 แดชบอร์ดผู้นำเทรด (Master)</h1>
            <p class="text-gray-500">ยินดีต้อนรับ, คุณ <%= @current_scope.user.name %>!</p>
          </div>
          <div class="text-right">
             <span class="block text-3xl font-bold text-indigo-600"><%= @follower_count %></span>
             <span class="text-xs text-gray-500 uppercase tracking-wide">ผู้ติดตาม</span>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="bg-gradient-to-br from-indigo-600 to-indigo-800 rounded-xl shadow-lg p-6 text-white relative overflow-hidden">
            <div class="relative z-10">
              <h2 class="text-lg font-medium opacity-90 mb-1">Master Token ของคุณ</h2>
              <p class="text-xs opacity-70 mb-3">ส่งรหัสนี้ให้ผู้ติดตาม เพื่อใช้เชื่อมต่อกับคุณ</p>

              <div class="bg-white/20 backdrop-blur-sm rounded-lg p-3 font-mono text-2xl font-bold tracking-wider text-center border border-white/30 select-all">
                <%= @master_token %>
              </div>
            </div>
            <div class="absolute -bottom-10 -right-10 w-40 h-40 bg-white/10 rounded-full blur-2xl"></div>
          </div>

          <div class="bg-white rounded-xl shadow-md border border-gray-200 p-6">
             <h2 class="text-lg font-bold text-gray-800 mb-2">📡 การเชื่อมต่อ EA</h2>
             <p class="text-sm text-gray-500 mb-4">นำคีย์นี้ไปใส่ในช่อง InpApiKey ของ "MasterSender" EA</p>

             <div class="bg-gray-100 rounded-lg p-3 font-mono text-sm text-gray-700 break-all border border-gray-200 select-all">
                <%= @api_key %>
             </div>
          </div>
        </div>

      <% else %>
        <div class="mb-8">
          <h1 class="text-3xl font-bold text-gray-900">🚀 พอร์ตโฟลิโอของฉัน</h1>
          <p class="text-gray-500">ระบบคัดลอกเทรดอัตโนมัติ สวัสดีคุณ <%= @current_scope.user.name %></p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
          <div class="md:col-span-2 bg-white rounded-xl shadow-md border border-gray-200 p-6">
            <h2 class="text-xl font-bold text-gray-800 mb-4">🔌 สถานะการเชื่อมต่อ</h2>

            <%= if @current_master do %>
              <div class="flex items-center bg-green-50 border border-green-200 rounded-lg p-4">
                <div class="h-12 w-12 rounded-full bg-green-100 flex items-center justify-center text-2xl mr-4">
                  🏆
                </div>
                <div>
                  <p class="text-sm text-green-800 font-bold">เชื่อมต่อกับ Master แล้ว</p>
                  <p class="text-lg font-bold text-gray-900"><%= @current_master.name %></p>
                  <p class="text-xs text-gray-500">Token: <%= @current_master.master_token %></p>
                </div>
              </div>
            <% else %>
              <div class="flex items-center bg-yellow-50 border border-yellow-200 rounded-lg p-4 mb-4">
                <div class="h-12 w-12 rounded-full bg-yellow-100 flex items-center justify-center text-2xl mr-4">
                  ⚠️
                </div>
                <div>
                  <p class="text-sm text-yellow-800 font-bold">ยังไม่ได้เชื่อมต่อ Master</p>
                  <p class="text-sm text-gray-600">คุณยังไม่ได้ติดตามใครในขณะนี้</p>
                </div>
              </div>

              <.link navigate="/masters" class="inline-flex items-center justify-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm w-full">
                🔍 ค้นหาผู้นำเทรด
              </.link>
            <% end %>
          </div>

          <div class="bg-gray-50 rounded-xl shadow-inner border border-gray-200 p-6">
             <h2 class="text-sm font-bold text-gray-500 uppercase mb-2">API Key ของคุณ</h2>
             <p class="text-xs text-gray-400 mb-3">สำหรับ SlaveTCP EA</p>
             <div class="bg-white rounded p-2 font-mono text-xs text-gray-600 break-all border select-all">
               <%= @api_key %>
             </div>
          </div>
        </div>

        <div class="mt-8 grid grid-cols-1 md:grid-cols-4 gap-4">
          <div class="bg-indigo-600 rounded-xl p-6 text-white shadow-lg">
             <div class="text-indigo-200 text-sm font-medium uppercase tracking-wider">กำไรรวม (Total Profit)</div>
             <div class="text-3xl font-bold mt-2">
               $ <%= :erlang.float_to_binary(@total_profit, decimals: 2) %>
             </div>
          </div>
        </div>

        <div class="mt-8">
          <h3 class="text-lg font-bold text-gray-900 mb-4">⚡ ออเดอร์ที่ถืออยู่ (Active Trades)</h3>
          <div class="overflow-hidden shadow ring-1 ring-black ring-opacity-5 sm:rounded-lg">
            <table class="min-w-full divide-y divide-gray-300">
              <thead class="bg-gray-50">
                <tr>
                  <th class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900">คู่เงิน</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">ประเภท</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">ราคาเปิด</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">สถานะ</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">เวลา</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200 bg-white">
                <%= for pair <- @active_pairs do %>
                  <tr>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-bold text-gray-900"><%= pair.symbol %></td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">Copy Trade</td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500"><%= pair.open_price %></td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm">
                      <span class={"inline-flex items-center rounded-md px-2 py-1 text-xs font-medium ring-1 ring-inset #{if pair.status == "OPEN", do: "bg-green-50 text-green-700 ring-green-600/20", else: "bg-yellow-50 text-yellow-800 ring-yellow-600/20"}"}>
                        <%= pair.status %>
                      </span>
                    </td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                      <%= Calendar.strftime(pair.inserted_at, "%H:%M:%S") %>
                    </td>
                  </tr>
                <% end %>
                <%= if @active_pairs == [] do %>
                   <tr><td colspan="5" class="text-center py-4 text-gray-500 italic">ไม่มีออเดอร์ที่ถืออยู่</td></tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <div class="mt-8 mb-12">
          <h3 class="text-lg font-bold text-gray-900 mb-4">📜 ประวัติการเทรด (History)</h3>
          <div class="overflow-hidden shadow ring-1 ring-black ring-opacity-5 sm:rounded-lg">
            <table class="min-w-full divide-y divide-gray-300">
              <thead class="bg-gray-50">
                <tr>
                  <th class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900">คู่เงิน</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">ราคาปิด</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">กำไร/ขาดทุน</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">เวลาปิด</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200 bg-white">
                <%= for pair <- @closed_pairs do %>
                  <tr>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900"><%= pair.symbol %></td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500"><%= pair.close_price %></td>
                    <td class={"whitespace-nowrap px-3 py-4 text-sm font-bold #{if pair.profit >= 0, do: "text-green-600", else: "text-red-600"}"}>
                      <%= if pair.profit > 0, do: "+", else: "" %><%= pair.profit %>
                    </td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                      <%= Calendar.strftime(pair.closed_at, "%d/%m %H:%M") %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>

    </div>
    """
  end
end
