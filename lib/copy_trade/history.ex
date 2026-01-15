defmodule CopyTrade.History do
  import Ecto.Changeset
  alias CopyTrade.{Repo, TradeHistory}

  # ฟังก์ชันสำหรับบันทึกผลการเทรด
  def create_log(attrs) do
    %TradeHistory{}
    |> cast(attrs, [:user_id, :symbol, :action, :price, :volume, :ticket, :status, :execution_time_ms])
    |> validate_required([:user_id, :symbol, :action, :status])
    |> Repo.insert()
  end
end