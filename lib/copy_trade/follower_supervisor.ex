defmodule CopyTrade.FollowerSupervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def add_follower(user_id, api_key) do
    child_spec = {CopyTrade.FollowerWorker, [user_id: user_id, api_key: api_key]}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def remove_follower(user_id) do
    case Registry.lookup(CopyTrade.FollowerRegistry, user_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  # เพิ่มฟังก์ชันนี้เพื่อดึงรายชื่อ User ID ทั้งหมดที่อยู่ในสมุดทะเบียน
  def list_active_followers do
    # เป็นท่าพิเศษของ Elixir ในการดึง Key ทั้งหมดจาก Registry
    Registry.select(CopyTrade.FollowerRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end