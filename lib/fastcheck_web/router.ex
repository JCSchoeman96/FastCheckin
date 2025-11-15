defmodule FastCheckWeb.Router do
  use PetalBlueprintWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PetalBlueprintWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FastCheckWeb do
    pipe_through :browser

    live "/", DashboardLive, :index
    live "/scan/:event_id", ScannerLive, :index
    live "/dashboard/occupancy/:event_id", OccupancyLive, :index
  end

  scope "/", FastCheckWeb do
    pipe_through :api

    get "/health", HealthController, :check
  end
end
