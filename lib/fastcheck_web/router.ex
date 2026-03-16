defmodule FastCheckWeb.Router do
  use FastCheckWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FastCheckWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug FastCheckWeb.Plugs.LoggerMetadata
    plug FastCheckWeb.Plugs.RateLimiter
  end

  pipeline :dashboard_auth do
    plug FastCheckWeb.Plugs.BrowserAuth
  end

  pipeline :scanner_auth do
    plug FastCheckWeb.Plugs.ScannerAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug FastCheckWeb.Plugs.LoggerMetadata
    plug FastCheckWeb.Plugs.RateLimiter
  end

  pipeline :api_authenticated do
    plug :accepts, ["json"]
    plug FastCheckWeb.Plugs.LoggerMetadata
    plug FastCheckWeb.Plugs.MobileAuth
    plug FastCheckWeb.Plugs.RateLimiter
  end

  # Mobile scanner API pipeline with JWT authentication
  # All routes using this pipeline will have current_event_id assigned from verified JWT
  pipeline :mobile_api do
    plug :accepts, ["json"]
    plug FastCheckWeb.Plugs.LoggerMetadata
    plug FastCheckWeb.Plugs.MobileAuth
    plug FastCheckWeb.Plugs.RateLimiter
  end

  pipeline :device_api do
    plug :accepts, ["json"]
    plug FastCheckWeb.Plugs.LoggerMetadata
    plug FastCheckWeb.Plugs.ApiAuth
    plug FastCheckWeb.Plugs.DeviceScope
    plug FastCheckWeb.Plugs.RateLimiter
  end

  pipeline :require_event_assignment do
    plug FastCheckWeb.Plugs.RequireEventAssignment
  end

  scope "/", FastCheckWeb do
    pipe_through [:browser, :dashboard_auth]

    live "/", DashboardLive, :index
    live "/dashboard", DashboardLive, :index
    live "/scan/:event_id", ScannerLive, :index
    live "/dashboard/occupancy/:event_id", OccupancyLive, :index
    get "/export/attendees/:event_id", ExportController, :export_attendees
    get "/export/check-ins/:event_id", ExportController, :export_check_ins
    delete "/logout", SessionController, :delete
  end

  scope "/", FastCheckWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create

    get "/scanner/login", ScannerSessionController, :new
    post "/scanner/login", ScannerSessionController, :create
    delete "/scanner/logout", ScannerSessionController, :delete
  end

  scope "/scanner", FastCheckWeb do
    pipe_through [:browser, :scanner_auth]

    post "/:event_id/operator", ScannerSessionController, :update_operator
    live "/:event_id", ScannerPortalLive, :index
  end

  scope "/api/v1", FastCheckWeb do
    pipe_through :api

    get "/health", HealthController, :check

    # Public mobile API routes
    scope "/mobile", Mobile do
      post "/login", AuthController, :login
    end
  end

  scope "/api/v1", FastCheckWeb.Api.V1 do
    pipe_through :api

    # Future-facing native-scanner scaffold. Android runtime must not depend on
    # this route until the current /api/v1/mobile contract is formally replaced.
    post "/device_sessions", DeviceSessionController, :create
  end

  scope "/api/v1", FastCheckWeb do
    pipe_through :api_authenticated

    post "/check-in", CheckInController, :create
    post "/check-in/batch", BulkCheckInController, :create
  end

  # Protected mobile API routes (JWT authentication required)
  # This is the active Android runtime contract today.
  scope "/api/v1/mobile", FastCheckWeb.Mobile do
    pipe_through :mobile_api

    # Download attendees for offline use
    get "/attendees", SyncController, :get_attendees

    # Upload scanned check-ins
    post "/scans", SyncController, :upload_scans
  end

  scope "/api/v1", FastCheckWeb.Api.V1 do
    pipe_through [:device_api, :require_event_assignment]

    # Future-facing native-scanner scaffold only. These routes are not part of
    # the active Android contract while the app still uses /api/v1/mobile/*.
    get "/events/:event_id/config", EventConfigController, :show
    get "/events/:event_id/package", PackageController, :show
    get "/events/:event_id/health", EventHealthController, :show
    post "/check_ins", CheckInController, :create
    post "/check_ins/flush", SyncFlushController, :create
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
