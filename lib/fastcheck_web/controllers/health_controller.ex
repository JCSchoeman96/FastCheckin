defmodule FastCheckWeb.HealthController do
  @moduledoc """
  Exposes a lightweight readiness probe that verifies pgBouncer can reach the
  PostgreSQL cluster before admitting traffic from the load balancer.
  """

  use FastCheckWeb, :controller

  require Logger

  alias Ecto.Adapters.SQL
  alias PetalBlueprint.Repo

  def check(conn, _params) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    case SQL.query(Repo, "SELECT 1", []) do
      {:ok, _result} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "healthy", timestamp: timestamp})

      {:error, reason} ->
        Logger.warning("pgBouncer health check failed: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unhealthy", timestamp: timestamp})
    end
  end
end
