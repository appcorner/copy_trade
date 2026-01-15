defmodule CopyTrade.FollowerWorker do
  use GenServer
  require Logger
  # เรียกใช้ Module History ที่เราเพิ่งสร้าง
  alias CopyTrade.History

  # --- Client API ---
  def start_link(args) do
    name = {:via, Registry, {CopyTrade.FollowerRegistry, args[:user_id]}}
    GenServer.start_link(__MODULE__, args, name: name)
  end

  # --- Server Callbacks ---
  @impl true
  def init(state) do
    Logger.info("✅ Follower #{state[:user_id]} Online!")
    Phoenix.PubSub.subscribe(CopyTrade.PubSub, "gold_signals")
    {:ok, state}
  end

  @impl true
  def handle_info({:trade_signal, signal}, state) do
    # Log รับทราบ (Debug)
    Logger.debug("🔔 [#{state[:user_id]}] Signal Received: #{signal.action}")

    Task.start(fn ->
      start_time = System.monotonic_time()

      # 1. ยิงคำสั่งเทรด (เรียกฟังก์ชันข้างล่าง)
      result = execute_trade(state[:user_id], signal)

      # 2. คำนวณเวลาที่ใช้
      duration = System.monotonic_time() - start_time
      ms = System.convert_time_unit(duration, :native, :millisecond)

      # เตรียมข้อมูลพื้นฐาน
      base_attrs = %{
        user_id: state[:user_id],
        symbol: signal.symbol,
        action: signal.action,
        volume: 0.01,
        execution_time_ms: ms
      }

      # 3. ตรวจสอบผลลัพธ์และบันทึกลง Database
      case result do
        {:ok, response} ->
          Logger.info("✅ [#{state[:user_id]}] Success Ticket: #{response["ticket"]} (#{ms}ms)")

          # บันทึกความสำเร็จลง DB
          History.create_log(Map.merge(base_attrs, %{
            status: "SUCCESS",
            ticket: response["ticket"],
            price: response["price"]
          }))

        {:error, reason} ->
          Logger.error("❌ [#{state[:user_id]}] Failed: #{inspect(reason)}")

          # บันทึกความล้มเหลวลง DB
          History.create_log(Map.merge(base_attrs, %{
            status: "FAILED",
            ticket: 0,
            price: 0.0
          }))
      end
    end)

    {:noreply, state}
  end

  # --- Private Functions ---
  defp execute_trade(user_id, signal) do
    # URL ของ Python Gateway (ปรับตามเครื่องคุณ)
    url = "http://localhost:5000/trade"

    body = %{
      user_id: user_id,
      symbol: signal.symbol,
      action: signal.action,
      volume: 0.01
    }

    # ใช้ Library Req ยิง POST
    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response} # ส่งข้อมูลกลับไปให้ handle_info

      {:ok, %{status: code, body: response}} ->
        {:error, "Status #{code}: #{inspect(response)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
