defmodule CopyTrade.FollowerWorker do
  use GenServer
  require Logger
  alias CopyTrade.TradePairContext # 🔥 อย่าลืมเติม alias นี้

  # --- Client API & Init (เหมือนเดิม) ---
  def start_link(args) do
    name = {:via, Registry, {CopyTrade.FollowerRegistry, args[:user_id]}}
    GenServer.start_link(__MODULE__, args, name: name)
  end

  def init(args) do
    # 🔥 แก้ตรงนี้: แปลง Keyword List ให้เป็น Map ก่อน
    state = Map.new(args)

    Logger.info("✅ Follower #{state[:user_id]} Online!")
    Phoenix.PubSub.subscribe(CopyTrade.PubSub, "gold_signals")

    # เพิ่ม multiplier ไว้คูณ Lot (Default 1.0)
    {:ok, Map.put(state, :multiplier, 1.0)}
  end

  # --- Handle Signal ---
  def handle_info({:trade_signal, signal}, state) do
    # Log รับทราบ (Debug)
    Logger.debug("🔔 [#{state[:user_id]}] Signal Received: #{signal.action}")

    Task.start(fn ->
      process_signal(signal, state)
    end)
    {:noreply, state}
  end

  # ------------------------------------------------------------------
  # 🟢 LOGIC 1: การเปิดออเดอร์ (OPEN_BUY, OPEN_SELL)
  # ------------------------------------------------------------------
  defp process_signal(%{action: "OPEN_" <> type} = signal, state) do
    # 1. กันซ้ำ: เช็คว่าเคยเปิด Master Ticket นี้ไปหรือยัง?
    if TradePairContext.exists?(state.user_id, signal.master_ticket) do
      Logger.warning("⚠️ [#{state.user_id}] Duplicate Signal Ignored: #{signal.master_ticket}")
    else
      # 2. คำนวณ Lot Size
      lot = Float.round(signal.volume * state.multiplier, 2)
      lot = max(lot, 0.01) # ขั้นต่ำ 0.01

      # 3. เตรียม Payload (แปลง OPEN_BUY -> BUY)
      payload = %{
        action: type, # "BUY" หรือ "SELL"
        symbol: signal.symbol,
        volume: lot,
        magic: 123456 # ใส่ Magic Number
      }

      # 4. ยิง API
      case execute_api(payload) do
        {:ok, response} ->
          slave_ticket = response["ticket"]
          Logger.info("✅ [#{state.user_id}] OPEN #{type} Ticket: #{slave_ticket}")

          # 5. บันทึกจับคู่ (สำคัญมาก!)
          db_result = TradePairContext.create_pair(%{
            user_id: state.user_id,
            master_ticket: signal.master_ticket,
            slave_ticket: slave_ticket,
            symbol: signal.symbol,
            status: "OPEN",
            open_price: response["price"]
          })

          case db_result do
            {:ok, _pair} ->
              Logger.info("💾 Saved TradePair for Master Ticket: #{signal.master_ticket}")

            {:error, changeset} ->
              # 🚨 จุดนี้จะบอกเราว่าทำไมบันทึกไม่ได้!
              Logger.error("❌ DB Insert Failed: #{inspect(changeset.errors)}")
          end

        {:error, reason} ->
          Logger.error("❌ [#{state.user_id}] Open Failed: #{inspect(reason)}")
      end
    end
  end

  # ------------------------------------------------------------------
  # 🔴 LOGIC 2: การปิดออเดอร์ (CLOSE)
  # ------------------------------------------------------------------
  defp process_signal(%{action: "CLOSE"} = signal, state) do
    # 1. ค้นหาว่า Master Ticket นี้ ตรงกับ Slave Ticket เลขอะไร?
    case TradePairContext.get_slave_ticket(state.user_id, signal.master_ticket) do
      nil ->
        Logger.error("⚠️ [#{state.user_id}] Order Not Found for Master Ticket: #{signal.master_ticket}")

      slave_ticket ->
        # 2. สั่งปิดออเดอร์
        payload = %{
          action: "CLOSE",
          ticket: slave_ticket,
          symbol: signal.symbol
        }

        case execute_api(payload) do
          {:ok, response} ->
            Logger.info("✂️ [#{state.user_id}] CLOSED Ticket: #{slave_ticket}")

            profit = response["profit"] || 0.0 # กันเหนียวถ้าไม่มีค่าส่งมา

            # 3. อัปเดต DB ว่าปิดแล้ว
            TradePairContext.mark_as_closed(state.user_id, signal.master_ticket, response["price"], profit)

          {:error, reason} ->
            Logger.error("❌ [#{state.user_id}] Close Failed: #{inspect(reason)}")
        end
    end
  end

  # --- Helper ยิง API ---
  defp execute_api(payload) do
    url = "http://localhost:5000/trade" # หรือ host.docker.internal
    case Req.post(url, json: payload) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: _, body: body}} -> {:error, body}
      {:error, reason} -> {:error, reason}
    end
  end
end
