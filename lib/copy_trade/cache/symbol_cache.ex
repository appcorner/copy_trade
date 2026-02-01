# lib/copy_trade/cache/symbol_cache.ex

defmodule CopyTrade.Cache.SymbolCache do
  use GenServer

  @table :user_symbol_cache

  # --- Client API ---

  def set_info(user_id, symbol, contract_size, digits) do
    # บันทึกลง ETS โดยใช้ {user_id, symbol} เป็น Primary Key
    :ets.insert(@table, {{user_id, symbol}, %{contract_size: contract_size, digits: digits}})
  end

  def get_info(user_id, symbol) do
    case :ets.lookup(@table, {user_id, symbol}) do
      [{_, info}] -> info
      [] -> nil
    end
  end

  # --- Server Callbacks ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  def init(:ok) do
    # สร้างตาราง ETS แบบกระจัดกระจาย (Public) เพื่อให้ทุก Process อ่านเขียนได้เร็ว
    :ets.new(@table, [:set, :public, :named_table, {:read_concurrency, true}, {:write_concurrency, true}])

    # ดึงข้อมูลจาก DB มาใส่ Cache รอไว้ (Warm-up)
    Task.start(fn ->
      IO.puts "[Cache] Starting UserSymbol warm-up..."
      
      CopyTrade.Accounts.list_all_user_symbols() # สร้างฟังก์ชันนี้เพื่อดึงข้อมูลทั้งหมด
      |> Enum.each(fn s ->
        set_info(s.user_id, s.symbol, s.contract_size, s.digits)
      end)

      IO.puts "[Cache] Warm-up complete!"
    end)

    {:ok, %{}}
  end
end
