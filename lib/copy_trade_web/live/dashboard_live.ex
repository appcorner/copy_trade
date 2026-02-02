defmodule CopyTradeWeb.DashboardLive do
  use CopyTradeWeb, :live_view

  alias CopyTrade.Accounts
  alias CopyTrade.TradePairContext

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    # เพิ่มการ Subscribe ช่องราคา
    if connected?(socket) do
      Phoenix.PubSub.subscribe(CopyTrade.PubSub, "market_prices") #
      # [cite_start]Phoenix.PubSub.subscribe(CopyTrade.PubSub, "trade_signals") # [cite: 1]
    end

    socket =
      socket
      |> assign(prices: %{}) # ป้องกัน Error key :prices not found
      |> (fn s -> if user.role == "master", do: assign_master_data(s, user), else: assign_follower_data(s, user) end).()

    {:ok, socket}
  end

  # เตรียมข้อมูลสำหรับ Master
  defp assign_master_data(socket, user) do
    # (ในอนาคต) ดึงจำนวนคนติดตามมาโชว์ตรงนี้
    follower_count = 0

    assign(socket,
      role: :master,
      page_title: "แดชบอร์ดผู้นำเทรด (Master)",
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
      page_title: "พอร์ตโฟลิโอของฉัน (My Portfolio)",
      api_key: user.api_key,
      current_master: current_master,
      # Assign data เข้าหน้าจอ
      active_pairs: active_pairs,
      closed_pairs: closed_pairs,
      total_profit: total_profit,
      prices: %{}
    )
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

  @impl true
  def handle_info(_msg, socket) do
     # เมื่อมี Signal เข้ามา (ไม่ว่าจะ Open หรือ Close) ให้ดึงข้อมูลใหม่
     user = socket.assigns.current_scope.user

     socket = assign(socket,
       active_pairs: TradePairContext.list_active_pairs(user.id),
       closed_pairs: TradePairContext.list_closed_pairs(user.id),
       total_profit: TradePairContext.get_total_profit(user.id)
     )
     {:noreply, socket}
  end

  # [NEW] รับ Event เมื่อกดปุ่ม Unfollow
  @impl true
  def handle_event("unfollow", _params, socket) do
    user = socket.assigns.current_scope.user

    # 1. อัปเดต Database (เลิกติดตาม)
    case Accounts.unfollow_master(user) do
      {:ok, _updated_user} ->

        # 2. [สำคัญ] แจ้ง EA ผ่าน TCP ทันที (Push Notification)
        # ค้นหา Socket ของ User คนนี้จาก Registry
        case Registry.lookup(CopyTrade.SocketRegistry, to_string(user.id)) do
          [{pid, _}] ->
            # สั่งให้ Socket Handler ส่งข้อความ "CMD_STOP" ไปหา EA เดี๋ยวนี้
            CopyTrade.SocketHandler.send_command(pid, "CMD_STOP")

          [] ->
            :ok # EA ไม่ได้ต่ออยู่ ก็ไม่ต้องทำอะไร
        end

        # 3. แจ้ง Worker ให้หยุด Logic ภายใน
        case Registry.lookup(CopyTrade.FollowerRegistry, user.id) do
          [{pid, _}] -> GenServer.cast(pid, {:update_master, nil})
          [] -> :ok
        end

        {:noreply,
         socket
         |> put_flash(:info, "ยกเลิกการติดตามแล้ว! สั่ง EA ปิดการทำงานทันที")
         |> assign(current_master: nil, active_pairs: [])} # Reset หน้าจอ

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "เกิดข้อผิดพลาด")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto py-8 px-4"> <%= if @role == :master do %>
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
              <div class="bg-white/20 backdrop-blur-sm rounded-lg p-3 font-mono text-base font-bold tracking-wider text-center border border-white/30 select-all">
                <%= @master_token %>
              </div>
            </div>
            <div class="absolute -bottom-10 -right-10 w-40 h-40 bg-white/10 rounded-full blur-2xl"></div>
          </div>

          <div class="bg-white rounded-xl shadow-md border border-gray-200 p-6">
             <h2 class="text-lg font-bold text-gray-800 mb-2">📡 การเชื่อมต่อ EA</h2>
             <p class="text-sm text-gray-500 mb-4">API Key สำหรับ "MasterSenderTCP" EA</p>
             <div class="bg-gray-100 rounded-lg p-3 font-mono text-sm text-gray-700 break-all border border-gray-200 select-all">
                <%= @api_key %>
             </div>
          </div>
        </div>

        <div class="p-6 bg-white border border-gray-200 rounded-xl shadow-sm mt-8">
          <h3 class="text-lg font-bold text-gray-800">Master Sender EA</h3>
          <p class="text-sm text-gray-500 mt-2">สำหรับบัญชี Master ที่ต้องการส่งสัญญาณ</p>
          <a href="/downloads/MasterSenderTCP_V6_2.ex5"
            class="inline-block mt-4 px-6 py-2 bg-indigo-600 text-white font-medium rounded-lg hover:bg-indigo-700 transition"
            download>
            📥 Download v6.2 (MQ5)
          </a>
        </div>

      <% else %>
        <div class="mb-8">
          <h1 class="text-3xl font-bold text-gray-900">🚀 พอร์ตโฟลิโอของฉัน</h1>
          <p class="text-gray-500">สวัสดีคุณ <%= @current_scope.user.name %></p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
          <div class="md:col-span-2 bg-white rounded-xl shadow-md border border-gray-200 p-6">
            <h2 class="text-xl font-bold text-gray-800 mb-4">🔌 สถานะการเชื่อมต่อ</h2>
            <%= if @current_master do %>
              <div class="flex items-center justify-between bg-green-50 border border-green-200 rounded-lg p-4">
                <div class="flex items-center">
                  <div class="h-12 w-12 rounded-full bg-green-100 flex items-center justify-center text-2xl mr-4">🏆</div>
                  <div>
                    <p class="text-sm text-green-800 font-bold">เชื่อมต่อกับ Master แล้ว</p>
                    <p class="text-lg font-bold text-gray-900"><%= @current_master.name %></p>
                    <p class="text-xs text-gray-500"><%= @current_master.master_token %></p>
                  </div>
                </div>
                <button phx-click="unfollow" data-confirm="ยืนยันการเลิกติดตาม?"
                  class="w-full sm:w-auto bg-white text-red-600 hover:text-red-700 border border-red-200 text-xs font-bold py-2 px-4 rounded shadow-sm transition-colors">
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
              <.link navigate="/masters" class="inline-flex items-center justify-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm w-full">
                🔍 ค้นหาผู้นำเทรด
              </.link>
            <% end %>
          </div>

          <div class="bg-indigo-600 rounded-xl p-6 text-white shadow-lg flex flex-col justify-center">
             <div class="text-indigo-200 text-sm font-medium uppercase tracking-wider mb-1">กำไรรวม (Total Profit)</div>
             <div class="text-4xl font-bold">
               $ <%= :erlang.float_to_binary(@total_profit, decimals: 2) %>
             </div>
             <div class="mt-2 text-xs text-indigo-300">อัปเดตล่าสุด: <%= format_bkk(DateTime.utc_now(), "%H:%M") %></div>
          </div>
        </div>

        <div class="mb-12">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-lg font-bold text-gray-900 flex items-center gap-2">
              ⚡ ออเดอร์ที่ถืออยู่ (Active Trades)
              <span class="inline-flex items-center rounded-md bg-green-50 px-2 py-1 text-xs font-medium text-green-700 ring-1 ring-inset ring-green-600/20 animate-pulse">Live</span>
            </h3>
          </div>

          <div class="bg-white shadow-sm ring-1 ring-gray-900/5 sm:rounded-xl overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-300">
              <thead class="bg-gray-50">
                <tr>
                  <th class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900">Symbol</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Type</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Lot (M → S)</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Price / SL-TP</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Status</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Time</th>
                  <th class="px-3 py-3.5 text-right text-sm font-semibold text-gray-900">Profit ($)</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200 bg-white">
                <%= for pair <- @active_pairs do %>
                  <tr class="hover:bg-gray-50 transition">
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm">
                      <div class="font-bold text-gray-900"><%= pair.master_trade.symbol %></div>
                      <div class="text-xs text-gray-500">#<%= pair.slave_ticket %></div>
                    </td>

                    <td class="whitespace-nowrap px-3 py-4 text-sm">
                      <div class="flex items-center gap-2">
                        <span class={"font-bold text-xs " <> if(pair.master_trade.type == "BUY", do: "text-green-600", else: "text-red-600")}>
                          M: <%= pair.master_trade.type %>
                        </span>

                        <span class="text-gray-400">→</span>

                        <%= if pair.slave_type do %>
                          <span class={
                            "inline-flex items-center rounded-md px-2 py-1 text-xs font-bold ring-1 ring-inset " <>
                            if(pair.slave_type == "BUY",
                              do: "bg-green-100 text-green-700 ring-green-600/20",
                              else: "bg-red-100 text-red-700 ring-red-600/20")
                          }>
                            <%= pair.slave_type %>
                          </span>
                        <% else %>
                          <span class="text-gray-400 text-xs">Waiting...</span>
                        <% end %>
                      </div>
                    </td>

                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500">
                      <div class="flex items-center gap-1">
                        <span class="text-gray-400"><%= pair.master_trade.volume || "-" %></span>
                        <svg class="w-3 h-3 text-gray-300" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 8l4 4m0 0l-4 4m4-4H3"></path></svg>
                        <span class="font-bold text-gray-900"><%= pair.slave_volume || "..." %></span>
                      </div>
                    </td>

                    <td class="whitespace-nowrap px-3 py-4 text-sm">
                      <div class="font-medium text-gray-900"><%= pair.open_price %></div> <div class="text-xs flex gap-2 mt-0.5">
                        <%= if pair.master_trade.sl && pair.master_trade.sl > 0 do %>
                          <span class="text-red-600 font-medium">SL: <%= pair.master_trade.sl %></span>
                        <% end %>
                        <%= if pair.master_trade.tp && pair.master_trade.tp > 0 do %>
                          <span class="text-green-600 font-medium">TP: <%= pair.master_trade.tp %></span>
                        <% end %>
                      </div>
                    </td>

                    <td class="whitespace-nowrap px-3 py-4 text-sm">
                      <span class={"inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium #{if pair.status == "OPEN", do: "bg-blue-50 text-blue-700", else: "bg-gray-100 text-gray-600"}"}>
                        <%= pair.status %>
                      </span>
                    </td>

                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-400">
                      <%= format_bkk(pair.inserted_at, "%H:%M:%S") %>
                    </td>

                    <td class="whitespace-nowrap px-3 py-4 text-sm text-right font-mono font-bold">
                      <%!-- เรียกใช้ Context ที่เราเตรียมไว้เพื่อคำนวณกำไรสดๆ --%>
                      <% floating_pl = TradePairContext.calculate_floating_profit(pair, @prices) %>
                      <span class={if floating_pl >= 0, do: "text-green-600", else: "text-red-600"}>
                        <%= if floating_pl > 0, do: "+", else: "" %><%= :erlang.float_to_binary(floating_pl, decimals: 2) %> $
                      </span>
                    </td>
                  </tr>
                <% end %>
                <%= if @active_pairs == [] do %>
                   <tr><td colspan="6" class="text-center py-8 text-gray-400">ไม่มีออเดอร์ที่ถืออยู่</td></tr>
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
                  <th class="py-3.5 pl-4 pr-3 text-left text-sm font-semibold text-gray-900">Symbol</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Type</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Open Price</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Close Price</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Lot</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Profit</th>
                  <th class="px-3 py-3.5 text-left text-sm font-semibold text-gray-900">Time</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200 bg-white">
                <%= for pair <- @closed_pairs do %>
                  <tr>
                    <td class="whitespace-nowrap py-4 pl-4 pr-3 text-sm font-medium text-gray-900"><%= pair.master_trade.symbol %></td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm">
                       <span class={"text-xs font-bold #{if pair.master_trade.type == "BUY", do: "text-green-600", else: "text-red-600"}"}>
                         <%= pair.master_trade.type %>
                       </span>
                    </td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500"><%= pair.open_price %></td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500"><%= pair.close_price %></td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500"><%= pair.slave_volume %></td>
                    <td class={"whitespace-nowrap px-3 py-4 text-sm font-bold #{if pair.profit >= 0, do: "text-green-600", else: "text-red-600"}"}>
                      <%= if pair.profit > 0, do: "+", else: "" %><%= pair.profit %> $
                    </td>
                    <td class="whitespace-nowrap px-3 py-4 text-sm text-gray-500"><%= format_bkk(pair.updated_at, "%d/%m %H:%M") %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <div class="p-6 bg-white border border-gray-200 rounded-xl shadow-sm">
          <h3 class="text-lg font-bold text-gray-800">Slave Copy EA</h3>
          <p class="text-sm text-gray-500 mt-2">สำหรับบัญชี Follower ที่ต้องการคัดลอกไม้</p>
          <a href="/downloads/SlaveTCP_V6_2.ex5"
            class="inline-block mt-4 px-6 py-2 bg-green-600 text-white font-medium rounded-lg hover:bg-green-700 transition"
            download>
            📥 Download v6.2 (MQ5)
          </a>
        </div>

      <% end %>
    </div>

    <footer class="bg-white py-6 border-t border-gray-200">
      <div class="mx-auto max-w-7xl px-6 text-center lg:px-8">
        <p class="text-sm leading-5 text-gray-500">
          <span>&copy; <%= Date.utc_today().year %> CopyTradePro. All rights reserved.</span>
          <span class="px-3 py-1 text-xs font-semibold bg-orange-100 text-orange600 rounded-full">
            v6.2.0 (Latest)
          </span>
        </p>
      </div>
    </footer>
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
