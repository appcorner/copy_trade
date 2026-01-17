defmodule CopyTradeWeb.Router do
  use CopyTradeWeb, :router

  import CopyTradeWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CopyTradeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CopyTradeWeb do
    pipe_through :browser

    # get "/", PageController, :home

    # live "/admin", AdminDashboardLive
  end

  scope "/", CopyTradeWeb do
    pipe_through [:browser, :require_authenticated_user]

    # 🔥 เพิ่มบรรทัดนี้: ให้หน้าแรกเป็น DashboardLive
    live "/", DashboardLive, :home

    # ... (route อื่นๆ เช่น users/settings) ...
    live "/masters", MasterBoardLive
  end

  # Other scopes may use custom stacks.
  scope "/api", CopyTradeWeb do
    pipe_through :api

    # เพิ่มบรรทัดนี้: เมื่อมีคนยิง POST มาที่ /webhook ให้เรียก WebhookController
    post "/webhook", WebhookController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:copy_trade, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CopyTradeWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", CopyTradeWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{CopyTradeWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", CopyTradeWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{CopyTradeWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
