defmodule CopyTradeWeb.AdminDashboardLive do
  use CopyTradeWeb, :live_view
  # alias CopyTrade.AdminContext

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # 🔥 1. สมัครรับข่าวสารจากหัวข้อ "admin_dashboard"
      Phoenix.PubSub.subscribe(CopyTrade.PubSub, "admin_dashboard")
    end

    # ดึง User เต็มๆ มา (ที่มีชื่อด้วย)
    users = CopyTrade.AdminContext.list_connected_users()

    {:ok, assign(socket, connected_users: users)}
  end

  # 🔥 3. ฟังก์ชันรับข่าว (Real-time update)
  @impl true
  def handle_info({:follower_status, user_info, :online}, socket) do
    # user_info ตอนนี้เป็น Map %{id: 1, name: "Boss", email: "..."}
    # เพิ่มเข้า list โดยกันซ้ำที่ ID
    new_list = [user_info | socket.assigns.connected_users]
               |> Enum.uniq_by(& &1.id)

    {:noreply, assign(socket, connected_users: new_list)}
  end

  @impl true
  def handle_info({:follower_status, user_info, :offline}, socket) do
    # ลบออกจาก list โดยเช็ค ID
    # user_info ที่ส่งมาตอน offline อาจมีแค่ id ก็พอ แต่ถ้าส่งมาเต็มก็กรองแบบนี้:
    target_id = if is_map(user_info), do: user_info.id, else: user_info

    new_list = Enum.reject(socket.assigns.connected_users, fn u -> u.id == target_id end)
    {:noreply, assign(socket, connected_users: new_list)}
  end

  # 🔥 4. ส่วนแสดงผล (HTML)
  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-8">
      <h1 class="text-2xl font-bold mb-4">🚀 แดชบอร์ดผู้ดูแลระบบ (Admin)</h1>

      <div class="bg-white shadow rounded-lg p-6">
        <h2 class="text-lg font-semibold mb-4 border-b pb-2">
          🔌 ผู้ใช้งานที่กำลังเชื่อมต่อ (TCP Clients)
          <span class="ml-2 bg-green-100 text-green-800 text-xs font-medium px-2.5 py-0.5 rounded">
            <%= length(@connected_users) %> ออนไลน์
          </span>
        </h2>

        <%= if @connected_users == [] do %>
          <p class="text-gray-500 italic">ไม่มีผู้ใช้งานเชื่อมต่อในขณะนี้</p>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <%= for user <- @connected_users do %>
              <div class="flex items-center p-3 border rounded-lg bg-gray-50 hover:bg-green-50 transition">
                <span class="relative flex h-3 w-3 mr-3">
                  <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-green-400 opacity-75"></span>
                  <span class="relative inline-flex rounded-full h-3 w-3 bg-green-500"></span>
                </span>

                <span class="font-mono font-medium text-gray-800">
                  <span class="font-bold text-gray-800">
                    <%= user.name || user.email %>
                  </span>
                  <span class="text-xs text-gray-500">รหัส: <%= user.id %></span>
                </span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

    </div>
    """
  end
end
