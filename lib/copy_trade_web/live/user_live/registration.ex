defmodule CopyTradeWeb.UserLive.Registration do
  use CopyTradeWeb, :live_view

  alias CopyTrade.Accounts
  alias CopyTrade.Accounts.User

@impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">

          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            required
            phx-mounted={JS.focus()}
          />

          <.input
            field={@form[:name]}
            type="text"
            label="Display Name (e.g. Trader Joe)"
            required
          />

          <div class="mt-6 pt-4 border-t border-gray-100">
            <label class="block text-sm font-semibold leading-6 text-zinc-800 mb-3">
              I want to be a...
            </label>

            <div class="grid grid-cols-2 gap-4">
              <label class="cursor-pointer group relative">
                <input type="radio" name="user[role]" value="follower" class="peer sr-only" checked={@form[:role].value == "follower" || is_nil(@form[:role].value)} />
                <div class="rounded-xl border-2 border-zinc-200 p-4 hover:border-zinc-400 peer-checked:border-indigo-600 peer-checked:bg-indigo-50 transition-all text-center h-full flex flex-col justify-center items-center">
                  <div class="text-3xl mb-2 grayscale group-hover:grayscale-0 peer-checked:grayscale-0">👥</div>
                  <span class="font-bold text-gray-900 block">Follower</span>
                  <span class="text-xs text-gray-500 mt-1">Copy others</span>
                </div>
              </label>

              <label class="cursor-pointer group relative">
                <input type="radio" name="user[role]" value="master" class="peer sr-only" checked={@form[:role].value == "master"} />
                <div class="rounded-xl border-2 border-zinc-200 p-4 hover:border-zinc-400 peer-checked:border-indigo-600 peer-checked:bg-indigo-50 transition-all text-center h-full flex flex-col justify-center items-center">
                  <div class="text-3xl mb-2 grayscale group-hover:grayscale-0 peer-checked:grayscale-0">🏆</div>
                  <span class="font-bold text-gray-900 block">Master</span>
                  <span class="text-xs text-gray-500 mt-1">Share signals</span>
                </div>
              </label>
            </div>

            <%= if @form[:role].errors != [] do %>
              <div class="mt-2 text-sm text-red-600">
                Please select a valid role.
              </div>
            <% end %>
          </div>

          <div class="mt-6">
            <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
              Create an account
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: CopyTradeWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           "An email was sent to #{user.email}, please access it to confirm your account."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
