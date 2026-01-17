defmodule CopyTradeWeb.DashboardLive do
  use CopyTradeWeb, :live_view

  on_mount {CopyTradeWeb.UserAuth, :require_sudo_mode}

  alias CopyTrade.Accounts

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

  # เตรียมข้อมูลสำหรับ Follower
  defp assign_follower_data(socket, user) do
    # ดึงข้อมูล Master ที่กำลังตามอยู่ (ถ้ามี)
    current_master = Accounts.get_following_master(user)

    assign(socket,
      role: :follower,
      page_title: "My Portfolio",
      api_key: user.api_key,
      current_master: current_master
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4">

      <%= if @role == :master do %>
        <div class="mb-8 flex items-center justify-between">
          <div>
            <h1 class="text-3xl font-bold text-gray-900">🏆 Master Dashboard</h1>
            <p class="text-gray-500">Welcome back, Commander <%= @current_scope.user.name %>!</p>
          </div>
          <div class="text-right">
             <span class="block text-3xl font-bold text-indigo-600"><%= @follower_count %></span>
             <span class="text-xs text-gray-500 uppercase tracking-wide">Followers</span>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="bg-gradient-to-br from-indigo-600 to-indigo-800 rounded-xl shadow-lg p-6 text-white relative overflow-hidden">
            <div class="relative z-10">
              <h2 class="text-lg font-medium opacity-90 mb-1">Your Master Token</h2>
              <p class="text-xs opacity-70 mb-3">Share this code with your followers</p>

              <div class="bg-white/20 backdrop-blur-sm rounded-lg p-3 font-mono text-2xl font-bold tracking-wider text-center border border-white/30 select-all">
                <%= @master_token %>
              </div>
            </div>
            <div class="absolute -bottom-10 -right-10 w-40 h-40 bg-white/10 rounded-full blur-2xl"></div>
          </div>

          <div class="bg-white rounded-xl shadow-md border border-gray-200 p-6">
             <h2 class="text-lg font-bold text-gray-800 mb-2">📡 EA Connection</h2>
             <p class="text-sm text-gray-500 mb-4">Enter this key in your "MasterSender" EA.</p>

             <div class="bg-gray-100 rounded-lg p-3 font-mono text-sm text-gray-700 break-all border border-gray-200 select-all">
               <%= @api_key %>
             </div>
          </div>
        </div>

      <% else %>

      <div class="mb-8">
          <h1 class="text-3xl font-bold text-gray-900">🚀 My Portfolio</h1>
          <p class="text-gray-500">Copy trading simplified. Hello, <%= @current_scope.user.name %>.</p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
          <div class="md:col-span-2 bg-white rounded-xl shadow-md border border-gray-200 p-6">
            <h2 class="text-xl font-bold text-gray-800 mb-4">🔌 Connection Status</h2>

            <%= if @current_master do %>
              <div class="flex items-center bg-green-50 border border-green-200 rounded-lg p-4">
                <div class="h-12 w-12 rounded-full bg-green-100 flex items-center justify-center text-2xl mr-4">
                  🏆
                </div>
                <div>
                  <p class="text-sm text-green-800 font-bold">Connected to Master</p>
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
                  <p class="text-sm text-yellow-800 font-bold">No Master Linked</p>
                  <p class="text-sm text-gray-600">You are not copying anyone yet.</p>
                </div>
              </div>

              <.link navigate="/masters" class="inline-flex items-center justify-center px-4 py-2 border border-transparent text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm w-full">
                🔍 Find a Master
              </.link>
            <% end %>
          </div>

          <div class="bg-gray-50 rounded-xl shadow-inner border border-gray-200 p-6">
             <h2 class="text-sm font-bold text-gray-500 uppercase mb-2">Your API Key</h2>
             <p class="text-xs text-gray-400 mb-3">For SlaveTCP EA</p>
             <div class="bg-white rounded p-2 font-mono text-xs text-gray-600 break-all border select-all">
               <%= @api_key %>
             </div>
          </div>
        </div>
      <% end %>

    </div>
    """
  end
end
