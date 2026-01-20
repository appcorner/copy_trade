defmodule CopyTrade.Notifier do
  require Logger

  # --- Telegram Config ---
  defp telegram_token, do: System.get_env("TELEGRAM_TOKEN")
  defp telegram_chat_id, do: System.get_env("TELEGRAM_CHAT_ID")

  # --- Discord Config ---
  defp discord_webhook_url, do: System.get_env("DISCORD_WEBHOOK_URL")

  # ฟังก์ชันยิงเข้า Telegram
  def send_telegram(message) do
    token = telegram_token()
    chat_id = telegram_chat_id()

    if token && chat_id do
      # ใช้ Task.start เพื่อไม่ให้เว็บอืด (Fire and Forget)
      Task.start(fn ->
        url = "https://api.telegram.org/bot#{token}/sendMessage"
        params = %{chat_id: chat_id, text: message}

        case Req.post(url, json: params) do
          {:ok, _} -> Logger.info("✅ Sent Telegram message")
          {:error, _} -> Logger.error("❌ Failed to send Telegram message")
        end
      end)
    end
  end

  # ฟังก์ชันยิงเข้า Discord
  def send_discord(message) do
    url = discord_webhook_url()

    if url do
      Task.start(fn ->
        params = %{content: message}
        Req.post(url, json: params)
      end)
    end
  end
end
