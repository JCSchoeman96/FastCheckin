defmodule FastCheckWeb.Observability.EndpointRequestLogPolicy do
  @moduledoc """
  Phoenix endpoint request-log policy for FastCheckWeb.

  Used as the dynamic `log:` MFA on `Plug.Telemetry` in `FastCheckWeb.Endpoint`.
  Suppresses Phoenix endpoint start/stop request logs for secure-ticket `/t/...`
  paths without disabling telemetry events or FastCheck observability handlers.
  """

  require Logger

  @default_endpoint_log_level :info

  @doc false
  @spec log_level(Plug.Conn.t()) :: Logger.level() | false
  def log_level(%Plug.Conn{request_path: request_path}) do
    if secure_ticket_request_path?(request_path) do
      false
    else
      @default_endpoint_log_level
    end
  end

  defp secure_ticket_request_path?(path) when is_binary(path) do
    String.starts_with?(path, "/t/")
  end

  defp secure_ticket_request_path?(_), do: true
end
