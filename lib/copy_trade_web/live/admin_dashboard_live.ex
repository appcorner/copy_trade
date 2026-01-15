defmodule CopyTradeWeb.AdminDashboardLive do
  use CopyTradeWeb, :live_view
  alias CopyTrade.FollowerSupervisor

  def mount(_params, _session, socket) do
    # ตอนเข้าหน้าเว็บ ดึงรายชื่อลูกค้าล่าสุดมาแสดง
    if connected?(socket) do
      # Subscribe รอฟังข่าวสาร (เผื่อมีคนอื่นเปิดหน้าจอนี้เหมือนกัน จะได้เห็นพร้อมกัน)
      Phoenix.PubSub.subscribe(CopyTrade.PubSub, "admin_updates")
    end

    {:ok, assign_data(socket)}
  end

  # ฟังก์ชันสำหรับ Render หน้า HTML
  def render(assigns) do
    ~H"""
    <div class="p-10 max-w-4xl mx-auto">
      <h1 class="text-3xl font-bold mb-6">🚀 Copy Trade Control Room</h1>

      <div class="bg-gray-100 p-6 rounded-lg mb-8 shadow">
        <h2 class="text-xl font-bold mb-4">📢 Master Signal</h2>
        <div class="flex gap-4">
          <button phx-click="broadcast_buy" class="bg-green-600 hover:bg-green-700 text-white font-bold py-3 px-6 rounded text-lg">
            BUY GOLD NOW!
          </button>
          <button phx-click="broadcast_sell" class="bg-red-600 hover:bg-red-700 text-white font-bold py-3 px-6 rounded text-lg">
            SELL GOLD NOW!
          </button>
        </div>
        <p class="mt-2 text-gray-500 text-sm">*กดแล้วดู Log ใน Terminal นะครับ</p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
        <div>
          <h2 class="text-xl font-bold mb-4">👥 Active Followers (<%= length(@followers) %>)</h2>
          
          <form phx-submit="add_user" class="flex gap-2 mb-4">
            <input type="text" name="user_id" placeholder="User ID (e.g. user99)" required 
                   class="border p-2 rounded flex-grow" />
            <button class="bg-blue-500 text-white px-4 py-2 rounded">Add</button>
          </form>

          <ul class="border rounded bg-white shadow divide-y">
            <%= for user_id <- @followers do %>
              <li class="p-3 flex justify-between items-center hover:bg-gray-50">
                <span class="font-mono text-lg">👤 <%= user_id %></span>
                <button phx-click="remove_user" phx-value-id={user_id} 
                        class="text-red-500 hover:text-red-700 font-bold border border-red-200 px-3 py-1 rounded text-sm">
                  Kick
                </button>
              </li>
            <% end %>
            <%= if @followers == [] do %>
              <li class="p-4 text-center text-gray-400">ยังไม่มีลูกค้า Online</li>
            <% end %>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  # --- Event Handlers (ส่วนรับคำสั่งจากปุ่ม) ---

  # 1. กดปุ่ม Add User
  def handle_event("add_user", %{"user_id" => user_id}, socket) do
    FollowerSupervisor.add_follower(user_id, "dummy_key")
    notify_update() # แจ้งเตือนให้หน้าจออัปเดต
    {:noreply, socket}
  end

  # 2. กดปุ่ม Kick User
  def handle_event("remove_user", %{"id" => user_id}, socket) do
    FollowerSupervisor.remove_follower(user_id)
    notify_update()
    {:noreply, socket}
  end

  # 3. กดปุ่มยิง Signal (BUY)
  def handle_event("broadcast_buy", _params, socket) do
    signal = %{symbol: "XAUUSD", price: 2050.00, action: "BUY"}
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "gold_signals", {:trade_signal, signal})
    {:noreply, put_flash(socket, :info, "🔥 Broadcast BUY Signal Sent!")}
  end
    
  # 4. กดปุ่มยิง Signal (SELL)
  def handle_event("broadcast_sell", _params, socket) do
    signal = %{symbol: "XAUUSD", price: 2040.00, action: "SELL"}
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "gold_signals", {:trade_signal, signal})
    {:noreply, put_flash(socket, :info, "📉 Broadcast SELL Signal Sent!")}
  end

  # --- Real-time Updates ---
  
  # รับแจ้งเตือนจาก PubSub ว่ามีข้อมูลเปลี่ยน ให้ดึงข้อมูลใหม่
  def handle_info(:refresh_list, socket) do
    {:noreply, assign_data(socket)}
  end

  # Helper: ดึงข้อมูลล่าสุดใส่ Socket
  defp assign_data(socket) do
    assign(socket, followers: FollowerSupervisor.list_active_followers())
  end

  # Helper: ส่งสัญญาณบอกทุกคนให้ Refresh หน้าจอ (PubSub)
  defp notify_update do
    Phoenix.PubSub.broadcast(CopyTrade.PubSub, "admin_updates", :refresh_list)
  end
end