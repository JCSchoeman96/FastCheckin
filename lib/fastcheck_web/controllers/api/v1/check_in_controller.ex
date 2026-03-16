defmodule FastCheckWeb.Api.V1.CheckInController do
  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  alias FastCheck.CheckIns

  def create(conn, params) do
    with {:ok, result} <- CheckIns.submit_scan(params, auth_context(conn)) do
      json(conn, %{data: result, error: nil})
    end
  end

  defp auth_context(conn) do
    %{
      device: conn.assigns.current_device,
      session: conn.assigns.current_device_session
    }
  end
end
