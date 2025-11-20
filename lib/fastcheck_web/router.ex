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

  # Mobile scanner API pipeline with JWT authentication
  # All routes using this pipeline will have current_event_id assigned from verified JWT
  pipeline :mobile_api do
    plug :accepts, ["json"]
    plug FastCheckWeb.Plugs.MobileAuth
  end

  scope "/", FastCheckWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/dashboard", DashboardLive, :index
    live "/scan/:event_id", ScannerLive, :index
    live "/dashboard/occupancy/:event_id", OccupancyLive, :index
  end

  scope "/", FastCheckWeb do
    pipe_through :api

    post "/check-in", CheckInController, :create
    get "/health", HealthController, :check
  end

  # Public mobile API routes (no authentication required)
  # Scanners use this to obtain JWT tokens
  scope "/api/mobile", FastCheckWeb.Mobile do
    pipe_through :api

    post "/login", AuthController, :login
  end

  # Protected mobile API routes (JWT authentication required)
  # All routes here have current_event_id assigned from the verified token
  scope "/api/mobile", FastCheckWeb.Mobile do
    pipe_through :mobile_api

    # Download attendees for offline use
    get "/attendees", SyncController, :get_attendees

    # Upload scanned check-ins
    post "/scans", SyncController, :upload_scans
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
