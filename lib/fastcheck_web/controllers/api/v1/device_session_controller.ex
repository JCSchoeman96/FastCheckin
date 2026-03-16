defmodule FastCheckWeb.Api.V1.DeviceSessionController do
  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  alias FastCheck.Devices

  def create(conn, params) do
    with {:ok, %{token: token, session: session, device: device, event: event}} <-
           Devices.create_session(params) do
      json(conn, %{
        data: %{
          token: token,
          device_id: device.id,
          session_id: session.id,
          event_id: event.id,
          gate_id: session.gate_id,
          expires_at: session.expires_at,
          server_time: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        },
        error: nil
      })
    end
  end
end
