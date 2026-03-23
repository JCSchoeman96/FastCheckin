defmodule FastCheckWeb.Api.V1.EventHealthController do
  @moduledoc false

  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  alias FastCheck.CheckIns
  alias FastCheck.Ticketing

  def show(conn, %{"event_id" => event_id_param}) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         %FastCheck.Ticketing.Event{} = event <- Ticketing.get_event(event_id) do
      json(conn, %{
        data: %{
          event_id: event.id,
          config_version: event.config_version,
          scanner_policy_mode: event.scanner_policy_mode,
          package: CheckIns.latest_package_metadata(event.id),
          session_id: conn.assigns.current_device_session.id,
          server_time: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        },
        error: nil
      })
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, {"INVALID", "event_id must be a positive integer"}}
    end
  end

  defp parse_event_id(_value), do: {:error, {"INVALID", "event_id must be a positive integer"}}
end
