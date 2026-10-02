defmodule FastCheckWeb.MetricsPlug do
  @moduledoc """
  Loopback-only Prometheus scrape handler for the dedicated metrics HTTP listener.

  Serves `TelemetryMetricsPrometheus.Core.scrape/0` on `GET /metrics` without routing
  through the public Phoenix endpoint.
  """

  import Plug.Conn

  @prometheus_content_type "text/plain; version=0.0.4; charset=utf-8"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{request_path: "/metrics"} = conn, _opts) do
    body = TelemetryMetricsPrometheus.Core.scrape()

    conn
    |> put_resp_content_type(@prometheus_content_type)
    |> send_resp(200, body)
  end

  def call(conn, _opts) do
    send_resp(conn, 404, "Not Found")
  end
end
