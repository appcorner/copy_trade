defmodule CopyTradeWeb.UserLive.Settings do
  use CopyTradeWeb, :live_view

  # on_mount {CopyTradeWeb.UserAuth, :require_sudo_mode}

  alias CopyTrade.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>

      <div class="divide-y divide-zinc-100">
        <div class="grid max-w-7xl grid-cols-1 gap-x-8 gap-y-10 px-4 py-16 sm:px-6 md:grid-cols-3 lg:px-8">
          <div>
            <h2 class="text-base font-semibold leading-7 text-zinc-900">API Key & Connection</h2>
            <p class="mt-1 text-sm leading-6 text-zinc-600">
              กุญแจสำคัญสำหรับเชื่อมต่อบัญชีเทรดของคุณเข้ากับระบบ
            </p>
          </div>

          <div class="md:col-span-2">
            <div class="rounded-xl bg-zinc-50 p-6 shadow-sm ring-1 ring-inset ring-zinc-200">
              <div class="flex items-center justify-between mb-4">
                <h3 class="text-sm font-bold text-zinc-900 flex items-center gap-2">
                  🔑 API Key ของคุณ
                </h3>
                <span class="inline-flex items-center rounded-md bg-green-50 px-2 py-1 text-xs font-medium text-green-700 ring-1 ring-inset ring-green-600/20">Active</span>
              </div>

              <div class="relative">
                <code class="block w-full rounded-lg bg-white px-4 py-3 text-sm font-mono text-indigo-600 shadow-sm ring-1 ring-inset ring-zinc-300 select-all break-all">
                  <%= @current_scope.user.api_key %>
                </code>
                <p class="mt-2 text-xs text-zinc-500 text-right">
                  (ดับเบิลคลิกเพื่อเลือกทั้งหมด)
                </p>
              </div>

              <div class="mt-4 border-t border-zinc-200 pt-4">
                <p class="text-xs text-zinc-600">
                  <strong>วิธีใช้งาน:</strong> นำรหัสนี้ไปวางในช่อง <code class="text-xs font-bold bg-zinc-200 px-1 rounded">คีย์ของ <%= if(@current_scope.user.role == "master", do: "Master", else: "Follower") %></code> ของ EA SlaveTCP บน MT5
                </p>
              </div>
            </div>

          </div>
        </div>
      </div>

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

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:name_form, to_form(name_changeset))
      |> assign(:trigger_submit, false)

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
