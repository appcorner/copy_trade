defmodule CopyTrade.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    # 🔥 เพิ่ม Field ตรงนี้ให้ตรงกับ Migration
    field :role, :string, default: "follower"
    field :api_key, :string
    field :master_token, :string

    field :name, :string

    # ความสัมพันธ์: 1 คน ตามได้ 1 Master (ในเวอร์ชั่นนี้)
    belongs_to :following, CopyTrade.Accounts.User, foreign_key: :following_id

    has_many :user_symbols, CopyTrade.Accounts.UserSymbol

    timestamps(type: :utc_datetime)
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  @doc """
  A changeset for registration.
  It computes the password hash and generates API Keys.
  """
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :password, :role, :name]) # 🔥 ใส่ :role และ :name ตรงนี้
    |> validate_email(opts)
    # |> validate_password(opts)
    # 🔥 เพิ่มการ Validate Role ตรงนี้
    |> validate_inclusion(:role, ["master", "follower"], message: "must be either master or follower")
    |> put_api_keys() # 🔥 สั่งสร้าง Key ตรงนี้
  end

  @doc """
  A changeset for changing the name.
  """
  def name_changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 50)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, CopyTrade.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Pbkdf2.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Pbkdf2.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%CopyTrade.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Pbkdf2.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Pbkdf2.no_user_verify()
    false
  end

  # 🔥 เพิ่มฟังก์ชันสุ่ม Key ท้ายไฟล์
  defp put_api_keys(changeset) do
    case changeset do
      %Ecto.Changeset{valid?: true} ->
        changeset
        |> put_change(:api_key, generate_key("sk_live_"))
        |> generate_master_token_if_needed()
      _ ->
        changeset
    end
  end

  defp generate_master_token_if_needed(changeset) do
    # ถ้า Role เป็น Master ให้สร้าง Token ด้วย
    if get_field(changeset, :role) == "master" do
      put_change(changeset, :master_token, generate_key("MST-"))
    else
      changeset
    end
  end

  defp generate_key(prefix) do
    # สร้างรหัสสุ่ม 16 ตัวอักษร
    random = :crypto.strong_rand_bytes(16) |> Base.encode16() |> String.downcase()
    prefix <> random
  end
end
