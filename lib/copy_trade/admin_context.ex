defmodule CopyTrade.AdminContext do
  alias CopyTrade.Accounts.User
  alias CopyTrade.Repo
  import Ecto.Query

  # ฟังก์ชันดึงรายชื่อ User ที่ต่อ Socket อยู่ตอนนี้
  def list_connected_users do
    # 1. ดึง ID ทั้งหมดจาก Registry (ได้เป็น List ของ String ["1", "2"])
    connected_ids =
      Registry.select(CopyTrade.SocketRegistry, [
        {{:"$1", :_, :_}, [], [:"$1"]}
      ])
      |> Enum.uniq()

    # 2. เอา ID ไป Query หาชื่อใน Database
    from(u in User,
      where: u.id in ^connected_ids,
      select: %{id: u.id, name: u.name, email: u.email}
    )
    |> Repo.all()
  end
end
