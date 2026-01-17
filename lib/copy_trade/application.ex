defmodule CopyTrade.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CopyTradeWeb.Telemetry,
      CopyTrade.Repo,
      {DNSCluster, query: Application.get_env(:copy_trade, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CopyTrade.PubSub},
      # Start a worker by calling: CopyTrade.Worker.start_link(arg)
      # {CopyTrade.Worker, arg},
      # Start to serve requests, typically the last entry

      # 1. สมุดทะเบียน
      {Registry, keys: :unique, name: CopyTrade.FollowerRegistry},

      # 🔥 2. เพิ่ม Registry ใหม่ (สำหรับ Socket Connection)
      {Registry, keys: :unique, name: CopyTrade.SocketRegistry},

      # 3. เพิ่ม TCP Server ที่เรากำลังจะสร้าง
      {CopyTrade.TCPServer, port: 5001},

      # 4. ผู้จัดการคนงาน
      CopyTrade.FollowerSupervisor,

      CopyTradeWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CopyTrade.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CopyTradeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
