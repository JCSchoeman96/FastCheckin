defmodule FastCheckWeb.Api.V1.EventConfigController do
  @moduledoc false

  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  alias FastCheck.CheckIns
  alias FastCheck.Ticketing
  alias FastCheck.Ticketing.EventConfigCache

  def show(conn, %{"event_id" => event_id_param}) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         %FastCheck.Ticketing.Event{} = event <- Ticketing.get_event(event_id) do
      payload =
        case EventConfigCache.get(event_id) do
          {:ok, %{} = cached} ->
            cached

          _ ->
            build_payload(event)
            |> tap(fn payload -> _ = EventConfigCache.put(event_id, payload) end)
        end

      json(conn, %{data: payload, error: nil})
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_payload(event) do
    gates =
      event.id
      |> Ticketing.list_gates()
      |> Enum.map(fn gate ->
        %{id: gate.id, name: gate.name, slug: gate.slug, status: gate.status}
      end)

    %{
      event_id: event.id,
      event_name: event.name,
      scanner_policy_mode: event.scanner_policy_mode,
      config_version: event.config_version,
      gates: gates,
      package: CheckIns.latest_package_metadata(event.id),
      server_time: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
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
