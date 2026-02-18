defmodule CopyTradeWeb.AccountLive.Index do
  use CopyTradeWeb, :live_view

  alias CopyTrade.Accounts
  alias CopyTrade.Accounts.TradingAccount

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if user do
      accounts = Accounts.list_trading_accounts(user.id)
      {:ok, assign(socket, :current_user, user) |> assign(:accounts, accounts)}
    else
      {:ok, redirect(socket, to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "My Accounts")
    |> assign(:trading_account, nil)
    |> assign(:accounts, Accounts.list_trading_accounts(socket.assigns.current_user.id))
  end

  defp apply_action(socket, :new, _params) do
    changeset = TradingAccount.changeset(%TradingAccount{}, %{})
    
    socket
    |> assign(:page_title, "New Trading Account")
    |> assign(:trading_account, %TradingAccount{})
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    account = Accounts.get_trading_account!(id)
    {:ok, _} = Accounts.delete_trading_account(account)

    {:noreply, assign(socket, :accounts, Accounts.list_trading_accounts(socket.assigns.current_user.id))}
  end

  @impl true
  def handle_event("validate", %{"trading_account" => params}, socket) do
    changeset =
      %TradingAccount{}
      |> TradingAccount.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"trading_account" => params}, socket) do
    case Accounts.create_trading_account(socket.assigns.current_user, params) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created successfully")
         |> push_patch(to: ~p"/accounts")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
end
