defmodule CopyTrade.FollowerWorker do
  use GenServer
  require Logger
  alias CopyTrade.History

  def start_link(args) do
    # ลงทะเบียนชื่อ Process ตาม User ID
    name = {:via, Registry, {CopyTrade.FollowerRegistry, args[:user_id]}}
    GenServer.start_link(__MODULE__, args, name: name)
  end

  def init(state) do
    Logger.info("✅ Follower #{state[:user_id]} Online!")
    Phoenix.PubSub.subscribe(CopyTrade.PubSub, "gold_signals")
    {:ok, state}
  end

  def handle_info({:trade_signal, signal}, state) do
    # Log จังหวะที่ 1: รับทราบคำสั่ง (อยู่ใน Process หลัก เร็วมาก)
    Logger.debug("🔔 [#{state[:user_id]}] Received signal, spawning task...")

    # จำลองการเทรดแบบไม่บล็อก (Async)
    Task.start(fn ->
      # --- เข้าสู่โลกของ Task (Async) ---

      # การ set metadata ช่วยให้ทุก log ใน task นี้มี user_id ติดไปด้วยอัตโนมัติ (ท่าโปร)
      Logger.metadata(user_id: state[:user_id])

      start_time = System.monotonic_time()

      # Log จังหวะที่ 2: เริ่มยิง (Start)
      Logger.info("🚀 Executing #{signal.action} #{signal.symbol}...")

      # เรียกฟังก์ชันยิง API
      result = execute_trade(state[:user_id], signal)

      # คำนวณเวลาที่ใช้ไป
      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      # เตรียมข้อมูลพื้นฐาน
      base_attrs = %{
        user_id: state[:user_id],
        symbol: signal.symbol,
        action: signal.action,
        volume: 0.01,
        execution_time_ms: duration_ms
      }

      # Log จังหวะที่ 3: สรุปผล (Finish)
      case result do
        {:ok, response} ->
          Logger.info("✅ Trade Success! Ticket: #{response["ticket"]} (Time: #{duration_ms}ms)")

          # 👇 บันทึกลง DB: Success
          History.create_log(Map.merge(base_attrs, %{
            status: "SUCCESS",
            ticket: response["ticket"], # เก็บ Ticket ไว้ปิดออเดอร์ทีหลัง
            price: response["price"]
          }))

        {:error, reason} ->
          Logger.error("❌ Trade Failed! Reason: #{inspect(reason)} (Time: #{duration_ms}ms)")

          # 👇 บันทึกลง DB: Failed (เอาไว้ Audit ว่าทำไมพัง)
          History.create_log(Map.merge(base_attrs, %{
            status: "FAILED",
            ticket: 0,
            price: 0.0
          }))
      end
    end)
    {:noreply, state}
  end

  defp execute_trade(user_id, signal) do
    # URL ของ Python Server ที่เราจะสร้างในอนาคต
    url = "http://127.0.0.1:5000/trade"

    body = %{
      user_id: user_id,
      symbol: signal.symbol,
      action: signal.action,
      volume: 0.01 # สมมติว่า Fixed lot
    }

    # ยิง Request!
    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: response}} ->
        Logger.info("✅ [#{user_id}] Order Executed Successfully!")
        {:ok, response}

      {:ok, %{status: code, body: response}} ->
        Logger.error("❌ [#{user_id}] Failed with status #{code}")
        {:error, "Status #{code}: #{inspect(response)}"}

      {:error, reason} ->
        Logger.error("⚠️ [#{user_id}] Network Error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
