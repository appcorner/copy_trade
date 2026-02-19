defmodule CopyTradeWeb.MasterBoardLive do
  use CopyTradeWeb, :live_view
  alias CopyTrade.Accounts

  @impl true
  def mount(_params, _session, socket) do
    masters = Accounts.list_pubsub_masters()

    {:ok,
     assign(socket,
       masters: masters,
       search: "",
       page_title: "เลือกผู้นำเทรด (Masters)"
     )}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    masters = Accounts.list_pubsub_masters(search)
    {:noreply, assign(socket, masters: masters, search: search)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-4xl mx-auto py-2">
        <%!-- Header --%>
        <div class="mb-5">
          <h1 class="text-2xl font-bold text-gray-900 tracking-tight">📡 เลือกผู้นำเทรด</h1>
          
          <p class="text-gray-500 text-sm mt-1">แสดงเฉพาะ Master ที่เปิดรับสมัครผู้ติดตาม (โหมด PUBSUB)</p>
        </div>
         <%!-- Search Filter --%>
        <div class="mb-5">
          <form phx-change="search" phx-submit="search" id="master-search-form">
            <div class="relative">
              <div class="pointer-events-none absolute inset-y-0 left-0 flex items-center pl-3">
                <svg
                  class="h-5 w-5 text-gray-400"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke-width="2"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M21 21l-5.197-5.197m0 0A7.5 7.5 0 105.196 5.196a7.5 7.5 0 0010.607 10.607z"
                  />
                </svg>
              </div>
              
              <input
                type="text"
                name="search"
                value={@search}
                placeholder="ค้นหาชื่อ Master..."
                phx-debounce="300"
                class="block w-full rounded-xl border border-gray-300 bg-white py-2.5 pl-10 pr-4 text-sm text-gray-900 placeholder-gray-400 shadow-sm focus:border-indigo-500 focus:ring-2 focus:ring-indigo-500/20 focus:outline-none transition"
                id="master-search-input"
              />
            </div>
          </form>
        </div>
         <%!-- Masters Grid --%>
        <div class="grid grid-cols-1 gap-6 sm:grid-cols-2">
          <%= for m <- @masters do %>
            <div
              class="relative flex flex-col bg-white rounded-xl border border-gray-200 shadow-sm p-6 hover:shadow-lg hover:border-indigo-300 transition-all duration-200 group"
              id={"master-card-#{m.master_id}"}
            >
              <div class="flex items-start justify-between mb-4">
                <div class="flex items-center gap-3">
                  <div class="w-12 h-12 rounded-xl bg-gradient-to-br from-indigo-100 to-indigo-200 flex items-center justify-center text-2xl border border-indigo-200/50 shadow-sm">
                    🏆
                  </div>
                  
                  <div>
                    <h2 class="text-lg font-bold text-gray-900 group-hover:text-indigo-600 transition-colors">
                      {m.name}
                    </h2>
                    
                    <span class="inline-flex items-center gap-1 text-xs text-gray-400">
                      <span class="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse"></span> PUBSUB
                    </span>
                  </div>
                </div>
                
                <div class="text-right">
                  <div class="flex items-center gap-1 text-indigo-600">
                    <svg
                      class="w-4 h-4"
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
                    </svg> <span class="text-sm font-bold">{m.follower_count}</span>
                  </div>
                   <span class="text-[10px] text-gray-400">ผู้ติดตาม</span>
                </div>
              </div>
              
              <div class="mt-auto bg-gray-50 rounded-lg px-3 py-3 border border-gray-100">
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <span class="text-[10px] text-gray-400 uppercase font-semibold tracking-wide">
                      Token
                    </span>
                    <div class="font-mono text-sm font-bold text-gray-700 select-all break-all">
                      {m.token}
                    </div>
                  </div>
                  
                  <button
                    id={"copy-token-#{m.master_id}"}
                    phx-hook="CopyText"
                    data-copy-text={m.token}
                    class="px-2.5 py-1.5 bg-indigo-600 text-white text-xs font-medium rounded-md hover:bg-indigo-700 active:scale-95 transition-all shadow-sm"
                  >
                    📋 Copy
                  </button>
                </div>
              </div>
            </div>
          <% end %>
        </div>
         <%!-- Empty State --%>
        <%= if @masters == [] do %>
          <div class="text-center py-12">
            <div class="text-4xl mb-3">🔍</div>
            
            <%= if @search != "" do %>
              <p class="text-gray-500 text-base">
                ไม่พบ Master ชื่อ "<span class="font-bold">{@search}</span>"
              </p>
              
              <p class="text-gray-400 text-sm mt-1">ลองค้นหาด้วยชื่ออื่น</p>
            <% else %>
              <p class="text-gray-500 text-base">ยังไม่มี Master ที่เปิดโหมด PUBSUB</p>
              
              <p class="text-gray-400 text-sm mt-1">กลับมาดูใหม่ภายหลังนะครับ</p>
            <% end %>
          </div>
        <% end %>
         <%!-- Info --%>
        <div class="mt-5 bg-indigo-50 border border-indigo-100 rounded-xl p-4">
          <div class="flex gap-3">
            <div class="text-xl flex-shrink-0">💡</div>
            
            <div class="text-sm text-indigo-800">
              <p class="font-bold mb-1">วิธีใช้งาน</p>
              
              <ol class="list-decimal list-inside space-y-0.5 text-indigo-700">
                <li>กด <span class="font-bold">📋 Copy</span> เพื่อคัดลอก Token ของ Master</li>
                
                <li>เปิด EA ใน MT5 แล้ววาง Token ที่ช่อง Master Token</li>
                
                <li>EA จะเชื่อมต่อกับ Master อัตโนมัติ</li>
              </ol>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
