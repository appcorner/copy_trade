defmodule CopyTradeWeb.UserLive.Settings do
  use CopyTradeWeb, :live_view

  # on_mount {CopyTradeWeb.UserAuth, :require_sudo_mode}

  alias CopyTrade.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>

      <div>
        <h3 class="text-base font-semibold leading-6 text-zinc-800 mb-1">🔑 API Keys สำหรับเชื่อมต่อ EA</h3>
        <p class="text-sm text-zinc-500 mb-4">ใช้ API Key นี้ในการตั้งค่า EA บน MT5 เพื่อเชื่อมต่อกับระบบ</p>

        <%= if @accounts == [] do %>
          <div class="rounded-lg bg-gray-50 border border-gray-200 p-6 text-center">
            <p class="text-sm text-gray-500">คุณยังไม่มีบัญชีเทรด</p>
            <.link navigate={~p"/accounts/new"} class="mt-2 inline-block text-sm font-semibold text-indigo-600 hover:text-indigo-500">
              สร้างบัญชีเทรดแรกของคุณ →
            </.link>
          </div>
        <% else %>
          <div class="space-y-3">
            <%= for account <- @accounts do %>
              <div class="rounded-xl border border-gray-200 bg-white p-4 shadow-sm">
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center gap-2">
                    <span class="text-lg"><%= if account.role == "master", do: "🏆", else: "👥" %></span>
                    <span class="font-bold text-gray-900"><%= account.name %></span>
                    <span class={"px-2 py-0.5 text-xs font-semibold rounded-full #{if account.role == "master", do: "bg-blue-100 text-blue-700", else: "bg-green-100 text-green-700"}"}
                    >
                      <%= String.upcase(account.role) %>
                    </span>
                  </div>
                </div>
                <div class="mt-2">
                  <label class="block text-xs font-medium text-gray-500 mb-1">API Key</label>
                  <div class="bg-gray-50 rounded-lg p-2.5 font-mono text-sm text-gray-700 break-all border border-gray-200 select-all">
                    <%= account.api_key %>
                  </div>
                </div>
                <%= if account.role == "master" && account.master_token do %>
                  <div class="mt-2">
                    <label class="block text-xs font-medium text-gray-500 mb-1">Master Token</label>
                    <div class="bg-indigo-50 rounded-lg p-2.5 font-mono text-sm text-indigo-700 break-all border border-indigo-200 select-all">
                      <%= account.master_token %>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <div class="divider" />

      <div class="text-center">
        <.header>
          ตั้งค่าบัญชี
          <:subtitle>จัดการชื่อ อีเมล และรหัสผ่านของคุณ</:subtitle>
        </.header>
      </div>

      <.form for={@name_form} id="name_form" phx-submit="update_name">
        <.input
          field={@name_form[:name]}
          type="text"
          label="ชื่อที่ใช้แสดง"
          autocomplete="name"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">เปลี่ยนชื่อ</.button>
      </.form>

      <div class="divider" />

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="อีเมล"
          autocomplete="username"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">เปลี่ยนอีเมล</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          autocomplete="username"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="รหัสผ่านใหม่"
          autocomplete="new-password"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="ยืนยันรหัสผ่านใหม่"
          autocomplete="new-password"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          บันทึกรหัสผ่าน
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    name_changeset = CopyTrade.Accounts.User.name_changeset(user, %{})
    accounts = Accounts.list_trading_accounts(user.id)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:name_form, to_form(name_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:accounts, accounts)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  # ใส่ต่อจาก handle_event อื่นๆ
  def handle_event("update_name", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.update_user_name(user, user_params) do
      {:ok, updated_user} ->
        info = "Name updated successfully."
        {:noreply, assign(socket, :current_user, updated_user) |> put_flash(:info, info)}

      {:error, changeset} ->
        {:noreply, assign(socket, :name_changeset, changeset)}
    end
  end
end
