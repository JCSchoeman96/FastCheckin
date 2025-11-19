defmodule FastCheckWeb.Router do
  use FastCheckWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FastCheckWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug FastCheckWeb.Plugs.RateLimiter
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug FastCheckWeb.Plugs.RateLimiter
  end

  scope "/", FastCheckWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/scan/:event_id", ScannerLive, :index
    live "/dashboard/occupancy/:event_id", OccupancyLive, :index
  end

  scope "/", FastCheckWeb do
    pipe_through :api

    post "/check-in", CheckInController, :create
    get "/health", HealthController, :check
  end

  if Application.compile_env(:fastcheck, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FastCheckWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
