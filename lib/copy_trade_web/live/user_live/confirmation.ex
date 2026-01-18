defmodule CopyTradeWeb.UserLive.Confirmation do
  use CopyTradeWeb, :live_view

  alias CopyTrade.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>ยินดีต้อนรับ {@user.email}</.header>
        </div>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="กำลังยืนยัน..."
            class="btn btn-primary w-full"
          >
            ยืนยันและคงสถานะล็อกอินไว้
          </.button>
          <.button phx-disable-with="กำลังยืนยัน..." class="btn btn-primary btn-soft w-full mt-2">
            ยืนยันและล็อกอินเฉพาะครั้งนี้
          </.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button phx-disable-with="กำลังเข้าสู่ระบบ..." class="btn btn-primary w-full">
              เข้าสู่ระบบ
            </.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="กำลังเข้าสู่ระบบ..."
              class="btn btn-primary w-full"
            >
              คงสถานะล็อกอินไว้บนอุปกรณ์นี้
            </.button>
            <.button phx-disable-with="กำลังเข้าสู่ระบบ..." class="btn btn-primary btn-soft w-full mt-2">
              ล็อกอินเฉพาะครั้งนี้
            </.button>
          <% end %>
        </.form>

        <p :if={!@user.confirmed_at} class="alert alert-outline mt-8">
          คำแนะนำ: หากคุณต้องการใช้รหัสผ่าน คุณสามารถเปิดใช้งานได้ในหน้าตั้งค่าผู้ใช้
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "ลิงก์ยืนยันไม่ถูกต้องหรือหมดอายุแล้ว")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
