defmodule CopyTrade.Accounts.UserNotifier do
  import Swoosh.Email

  alias CopyTrade.Mailer
  alias CopyTrade.Accounts.User
  alias CopyTrade.Notifier


  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(get_sender())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end
  
  defp get_sender do
    config = Application.get_env(:copy_trade, :email_sender)
    {config[:name], config[:email]}
  end

  defp notify(title, email, url) do
    message = """
    🚀 **#{title}**
    User: #{email}
    Link: #{url}
    """

    Notifier.send_telegram(message)
    Notifier.send_discord(message)
  end


  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    notify("Update email Link Requested", user.email, url)

    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    notify("Log in Link Requested", user.email, url)

    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    notify("Confirmation Link Requested", user.email, url)

    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
