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
    new_list =
      [user_info | socket.assigns.connected_users]
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
    <div class="max-w-4xl mx-auto py-2">
      <%!-- Header --%>
      <div class="mb-5">
        <h1 class="text-2xl font-bold text-gray-900 tracking-tight">🚀 แดชบอร์ดผู้ดูแลระบบ</h1>
        
        <p class="text-gray-500 text-sm mt-1">จัดการและตรวจสอบสถานะการเชื่อมต่อทั้งหมด</p>
      </div>
       <%!-- Stats Summary --%>
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-5">
        <div class="bg-white rounded-xl border border-gray-200 shadow-sm p-4">
          <div class="text-xs text-gray-400 uppercase tracking-wide font-semibold mb-1">ออนไลน์</div>
          
          <div class="text-3xl font-bold text-emerald-600">{length(@connected_users)}</div>
        </div>
        
        <div class="bg-white rounded-xl border border-gray-200 shadow-sm p-4">
          <div class="text-xs text-gray-400 uppercase tracking-wide font-semibold mb-1">
            สถานะเซิร์ฟเวอร์
          </div>
          
          <div class="text-lg font-bold text-emerald-600 flex items-center gap-2">
            <span class="w-2 h-2 rounded-full bg-emerald-400 animate-pulse"></span> Running
          </div>
        </div>
        
        <div class="bg-white rounded-xl border border-gray-200 shadow-sm p-4">
          <div class="text-xs text-gray-400 uppercase tracking-wide font-semibold mb-1">TCP Port</div>
          
          <div class="text-lg font-bold text-gray-700 font-mono">4000</div>
        </div>
      </div>
       <%!-- Connected Users --%>
      <div class="bg-white rounded-xl border border-gray-200 shadow-sm p-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-bold text-gray-900">🔌 ผู้ใช้งานที่เชื่อมต่อ (TCP Clients)</h2>
          
          <span class="inline-flex items-center gap-1.5 rounded-full bg-emerald-50 px-3 py-1 text-xs font-semibold text-emerald-700 border border-emerald-200">
            <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span> {length(
              @connected_users
            )} ออนไลน์
          </span>
        </div>
        
        <%= if @connected_users == [] do %>
          <div class="text-center py-10">
            <div class="text-4xl mb-3">📭</div>
            
            <p class="text-gray-500 text-base">ไม่มีผู้ใช้งานเชื่อมต่อในขณะนี้</p>
            
            <p class="text-gray-400 text-sm mt-1">รอ EA เชื่อมต่อเข้ามา...</p>
          </div>
        <% else %>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <%= for user <- @connected_users do %>
              <div class="relative flex flex-col bg-white rounded-xl border border-gray-200 shadow-sm p-4 hover:shadow-md hover:border-emerald-300 transition-all duration-200 group">
                <div class="flex items-center gap-3">
                  <div class="relative flex-shrink-0">
                    <div class="w-10 h-10 rounded-xl bg-gradient-to-br from-emerald-50 to-emerald-100 border border-emerald-200/50 flex items-center justify-center text-lg shadow-sm">
                      👤
                    </div>
                    
                    <span class="absolute -bottom-0.5 -right-0.5 w-3 h-3 rounded-full bg-emerald-400 border-2 border-white">
                    </span>
                  </div>
                  
                  <div class="min-w-0">
                    <h3 class="text-base font-bold text-gray-900 group-hover:text-emerald-600 transition-colors truncate">
                      {user.name || user.email}
                    </h3>
                     <span class="text-xs text-gray-400 font-mono">ID: {user.id}</span>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
