defmodule FastCheckWeb.HealthController do
  @moduledoc """
  Exposes a lightweight readiness probe that verifies pgBouncer can reach the
  PostgreSQL cluster before admitting traffic from the load balancer.
  """

  use FastCheckWeb, :controller

  require Logger

  alias Ecto.Adapters.SQL
  alias FastCheck.Repo

  def check(conn, _params) do
    case SQL.query(Repo, "SELECT 1", []) do
      {:ok, _result} ->
        conn
        |> put_status(:ok)
        |> json(%{data: %{status: "healthy", timestamp: DateTime.utc_now()}, error: nil})

      {:error, reason} ->
        Logger.warning("pgBouncer health check failed: #{inspect(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{
          data: %{status: "unhealthy", timestamp: DateTime.utc_now()},
          error: %{code: "HEALTH_CHECK_FAILED", message: "Database unreachable"}
        })
    end
  end
end
