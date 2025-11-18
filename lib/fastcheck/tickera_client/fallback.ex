defmodule FastCheck.TickeraClient.Fallback do
  @moduledoc """
  Provides cached Tickera attendee data when the remote API is unreachable.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias FastCheck.Repo
  alias FastCheck.{Attendees.Attendee, Events.Event}

  @no_cached "NO_CACHED_DATA"
  @timeout_reasons [:timeout, :connect_timeout, :closed, :nxdomain, :enetunreach, :econnrefused]

  @type reason :: {:server_error, integer(), any()} | {:http_error, integer(), any()} |
          {:network_timeout, term()} | {:network_error, term()} | term()

  @doc """
  Returns cached attendees for the event tied to the provided credentials when the
  Tickera API cannot be reached. Logs the fallback event with the current UTC
  timestamp.
  """
  @spec maybe_use_cached(String.t(), String.t(), reason()) :: {:ok, list()} | {:error, String.t()}
  def maybe_use_cached(site_url, api_key, reason) when is_binary(site_url) and is_binary(api_key) do
    if unreachable?(reason) do
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

      with {:ok, %Event{} = event} <- fetch_event(api_key, site_url),
           {:ok, attendees} <- fetch_cached_attendees(event.id) do
        Logger.warn(
          "Tickera fallback activated for event #{event.id} at #{timestamp}: #{inspect(reason)}"
        )

        {:ok, attendees}
      else
        {:error, error_reason} ->
          Logger.warn(
            "Tickera fallback unavailable for API key #{redact(api_key)} at #{timestamp}: #{inspect(error_reason)}"
          )

          {:error, @no_cached}
      end
    else
      {:error, @no_cached}
    end
  end

  def maybe_use_cached(_site_url, _api_key, _reason), do: {:error, @no_cached}

  @doc """
  Determines if the provided error represents an unreachable Tickera API.
  """
  @spec unreachable?(reason()) :: boolean()
  def unreachable?({:server_error, code, _}) when is_integer(code) and code >= 500, do: true
  def unreachable?({:http_error, code, _}) when is_integer(code) and code >= 500, do: true
  def unreachable?({:network_timeout, _}), do: true

  def unreachable?({:network_error, reason}) do
    reason in @timeout_reasons
  end

  def unreachable?({:error, reason}), do: unreachable?(reason)
  def unreachable?(_), do: false

  defp fetch_event(api_key, _site_url) do
    case Repo.get_by(Event, api_key: api_key) do
      %Event{} = event -> {:ok, event}
      nil -> {:error, :event_not_found}
    end
  end

  defp fetch_cached_attendees(event_id) do
    attendees =
      from(a in Attendee,
        where: a.event_id == ^event_id,
        order_by: [asc: a.inserted_at]
      )
      |> Repo.all()
      |> Enum.map(&to_tickera_payload/1)

    case attendees do
      [] -> {:error, @no_cached}
      list -> {:ok, list}
    end
  end

  defp to_tickera_payload(%Attendee{} = attendee) do
    base = %{
      "ticket_code" => attendee.ticket_code,
      "first_name" => attendee.first_name,
      "last_name" => attendee.last_name,
      "ticket_type" => attendee.ticket_type,
      "ticket_type_id" => attendee.ticket_type_id,
      "allowed_checkins" => attendee.allowed_checkins,
      "custom_fields" => normalize_custom_fields(attendee.custom_fields)
    }

    maybe_append_email(base, attendee.email)
  end

  defp normalize_custom_fields(list) when is_list(list) do
    Enum.map(list, fn
      %{"name" => name, "value" => value} = field -> field
      %{name: name, value: value} -> %{"name" => name, "value" => value}
      {name, value} -> %{"name" => to_string(name), "value" => value}
      other -> %{"name" => "field", "value" => inspect(other)}
    end)
  end

  defp normalize_custom_fields(%{} = map) do
    Enum.map(map, fn {key, value} -> %{"name" => to_string(key), "value" => value} end)
  end

  defp normalize_custom_fields(_), do: []

  defp maybe_append_email(payload, nil), do: payload

  defp maybe_append_email(%{"custom_fields" => fields} = payload, email) when is_binary(email) do
    if Enum.any?(fields, &email_field?/1) do
      payload
    else
      updated = [%{"name" => "Email", "value" => email} | fields]
      Map.put(payload, "custom_fields", updated)
    end
  end

  defp email_field?(%{"name" => name}) when is_binary(name) do
    name |> String.downcase() |> String.contains?("email")
  end

  defp email_field?(%{name: name}) when is_binary(name) do
    name |> String.downcase() |> String.contains?("email")
  end

  defp email_field?(_), do: false

  defp redact(api_key) when is_binary(api_key) do
    if byte_size(api_key) <= 6 do
      "***"
    else
      suffix = String.slice(api_key, -4, 4)
      "***#{suffix}"
    end
  end
end
