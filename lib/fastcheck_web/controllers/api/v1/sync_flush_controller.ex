defmodule FastCheckWeb.Api.V1.SyncFlushController do
  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  alias FastCheck.CheckIns

  def create(conn, %{"scans" => scans}) when is_list(scans) do
    with {:ok, results} <- CheckIns.flush_scans(scans, auth_context(conn)) do
      json(conn, %{data: %{results: results, count: length(results)}, error: nil})
    end
  end

  def create(_conn, _params), do: {:error, {"INVALID", "scans must be an array"}}

  defp auth_context(conn) do
    %{
      device: conn.assigns.current_device,
      session: conn.assigns.current_device_session
    }
  end
end
