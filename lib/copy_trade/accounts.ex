defmodule CopyTrade.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias CopyTrade.Repo

  alias CopyTrade.Accounts.{User, UserToken, UserNotifier, UserSymbol, TradingAccount}
  alias CopyTrade.MasterTrade

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  # ใน Accounts Context
  def get_account_by_api_key(api_key) do
    Repo.get_by(TradingAccount, api_key: api_key) |> Repo.preload(:user)
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `CopyTrade.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `CopyTrade.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  def update_user_name(user, attrs) do
    user
    |> User.name_changeset(attrs)
    |> Repo.update()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  # --- Trading Account Management ---

  def get_trading_account!(id), do: Repo.get!(TradingAccount, id)

  def list_trading_accounts(user_id) do
    Repo.all(from t in TradingAccount, where: t.user_id == ^user_id)
  end

  def create_trading_account(user, attrs) do
    %TradingAccount{}
    |> TradingAccount.changeset(Map.put(attrs, "user_id", user.id))
    |> Repo.insert()
  end

  def delete_trading_account(%TradingAccount{} = account) do
    Repo.delete(account)
  end

  def update_copy_mode(%TradingAccount{} = account, mode) do
    account
    |> Ecto.Changeset.change(%{copy_mode: mode})
    |> Ecto.Changeset.validate_inclusion(:copy_mode, ["1TO1", "PUBSUB", "RECORD"])
    |> Repo.update()
  end

  # ดึงรายชื่อ Master พร้อมจำนวนผู้ติดตาม
  def list_masters_with_counts do
    from(t in TradingAccount,
      where: t.role == "master" and t.is_active == true,
      left_join: f in TradingAccount, on: f.following_id == t.id,
      group_by: t.id,
      select: %{
        master_id: t.id,
        name: t.name,
        token: t.master_token,
        follower_count: count(f.id)
      }
    )
    |> Repo.all()
  end

  # ฟังก์ชันหา Master จาก Token (ใช้ตอน Subscribe)
  def get_master_account_by_token(token) do
    Repo.get_by(TradingAccount, master_token: token)
  end

  # ฟังก์ชันอัปเดตการติดตาม (ใช้ตอน EA ส่ง Subscribe มา)
  def link_follower_to_master(follower_id, master_id) do
    get_trading_account!(follower_id)
    |> Ecto.Changeset.change(%{following_id: master_id})
    |> Repo.update()
  end

  # [NEW] ฟังก์ชันสำหรับกดยกเลิกการติดตาม
  def unfollow_master(account_id) do
    get_trading_account!(account_id)
    |> Ecto.Changeset.change(%{following_id: nil})
    |> Repo.update()
  end

  def get_following_master(account_id) do
    account = get_trading_account!(account_id) |> Repo.preload(:following)
    account.following
  end

  def update_account_copy_mode(account_id, mode) when mode in ["1TO1", "PUBSUB"] do
    account = get_trading_account!(account_id)

    account
    |> Ecto.Changeset.cast(%{copy_mode: mode, partner_id: nil}, [:copy_mode, :partner_id])
    |> Repo.update()
  end

  # แถม: ฟังก์ชันสำหรับ Bind คู่แท้ (Partner)
  def bind_partner(master_id, follower_id) do
    # find partner_id exist in other master and remove it
    query = from t in TradingAccount,
              where: t.partner_id == ^follower_id and t.id != ^master_id,
              select: t.id
    
    Repo.all(query)
    |> Enum.each(fn other_master_id ->
      unbind_partner(other_master_id)
    end)

    master = get_trading_account!(master_id)

    master
    |> Ecto.Changeset.cast(%{partner_id: follower_id}, [:partner_id])
    |> Repo.update()
  end

  def unbind_partner(master_id) do
    master = get_trading_account!(master_id)

    master
    |> Ecto.Changeset.cast(%{partner_id: nil}, [:partner_id])
    |> Repo.update()
  end
  
  # Note: logic for symbols still uses user_id for now as requested plan did not specify migrating symbols.
  # Ideally we should migrate UserSymbol to AccountSymbol later.

  def upsert_user_symbol(account_id, symbol, contract_size, digits) do
    attrs = %{account_id: account_id, symbol: symbol, contract_size: contract_size, digits: digits}

    case Repo.get_by(UserSymbol, account_id: account_id, symbol: symbol) do
      nil -> %UserSymbol{}
      existing -> existing
    end
    |> UserSymbol.changeset(attrs)
    |> Repo.insert_or_update()
  end

  def list_all_user_symbols do
    Repo.all(UserSymbol)
  end

  def get_master_total_profit(master_account_id) do
    from(mt in MasterTrade,
      where: mt.master_id == ^master_account_id and mt.status == "CLOSED",
      select: sum(mt.profit)
    )
    |> Repo.one()
    |> case do
      nil -> 0.0
      profit -> profit
    end
  end
end

