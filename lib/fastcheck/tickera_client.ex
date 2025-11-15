defmodule FastCheck.TickeraClient do
  @moduledoc """
  HTTP client responsible for communicating with the Tickera WordPress plugin API.
  """

  require Logger

  @timeout 30_000
  @pagination_delay 100

  @doc """
  Validates the provided API credentials against the Tickera API.

  ## Parameters
    * `site_url` - Base URL of the WordPress site hosting Tickera.
    * `api_key` - Tickera API key.

  ## Returns
    * `{:ok, response_map}` on success.
    * `{:error, reason}` on failure.
  """
  @spec check_credentials(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def check_credentials(site_url, api_key) do
    site_url
    |> build_url(api_key, "check_credentials")
    |> fetch_json()
  end

  @doc """
  Fetches summary details for the configured event.

  The returned map includes the event name, start time, and ticket statistics. The
  `"event_date_time"` field is normalized to a `DateTime`/`NaiveDateTime` when possible
  via `parse_datetime/1`.

  ## Returns
    * `{:ok, response_map}` on success.
    * `{:error, reason}` on failure.
  """
  @spec get_event_essentials(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def get_event_essentials(site_url, api_key) do
    url = build_url(site_url, api_key, "event_essentials")

    with {:ok, data} <- fetch_json(url) do
      normalized = Map.update(data, "event_date_time", nil, &parse_datetime/1)
      {:ok, normalized}
    end
  end

  @doc """
  Retrieves ticket information for a specific page.

  ## Parameters
    * `site_url` - Base Tickera site URL.
    * `api_key` - Tickera API key.
    * `per_page` - Number of records per page (default 50).
    * `page` - Page number to fetch (default 1).
  """
  @spec get_tickets_info(String.t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, String.t()}
  def get_tickets_info(site_url, api_key, per_page \\ 50, page \\ 1) do
    per_page = max(1, per_page)
    page = max(1, page)

    endpoint = "tickets_info/#{per_page}/#{page}/"

    site_url
    |> build_url(api_key, endpoint)
    |> fetch_json()
  end

  @doc """
  Fetches all attendees by iterating through every results page.

  An optional `callback` function can be provided. It is invoked for each page with
  `(page_number, total_pages, count_for_page)`.

  ## Returns
    * `{:ok, attendees, total_count}` on full success.
    * `{:error, reason, partial_attendees}` if any request fails.
  """
  @spec fetch_all_attendees(String.t(), String.t(), pos_integer(),
          ((pos_integer(), pos_integer(), non_neg_integer()) -> any()) | nil) ::
          {:ok, list(), non_neg_integer()} | {:error, String.t(), list()}
  def fetch_all_attendees(site_url, api_key, per_page \\ 50, callback \\ nil) do
    per_page = max(1, per_page)

    case get_tickets_info(site_url, api_key, per_page, 1) do
      {:ok, %{"data" => data} = first_resp} ->
        additional = Map.get(first_resp, "additional", %{})
        total_count = Map.get(additional, "results_count") || length(data)

        total_pages =
          total_count
          |> max(length(data))
          |> then(&ceil(&1 / per_page))
          |> max(1)

        parsed = Enum.map(data, &parse_attendee/1)
        maybe_callback(callback, 1, total_pages, length(data))

        acc = Enum.reduce(parsed, [], fn attendee, acc -> [attendee | acc] end)

        case do_fetch_attendees(site_url, api_key, per_page, 2, total_pages, callback, acc) do
          {:ok, attendees} -> {:ok, attendees, total_count}
          {:error, reason, partial} -> {:error, reason, partial}
        end

      {:error, reason} ->
        {:error, reason, []}

      other ->
        {:error, "HTTP error: unexpected response #{inspect(other)}", []}
    end
  end

  @doc """
  Normalizes a raw Tickera ticket payload into a FastCheck attendee map.

  Extracts email and ticket type from `custom_fields` when available.
  """
  @spec parse_attendee(map()) :: map()
  def parse_attendee(ticket_data) when is_map(ticket_data) do
    custom_fields =
      ticket_data
      |> Map.get("custom_fields", [])
      |> List.wrap()

    {email, ticket_type, custom_map} =
      Enum.reduce(custom_fields, {nil, nil, []}, fn field, {email_acc, type_acc, acc} ->
        name = Map.get(field, "name") || Map.get(field, "field")
        value = Map.get(field, "value")
        normalized = %{name: name, value: value}

        email_acc = email_acc || email_from_field(name, value)
        type_acc = type_acc || ticket_type_from_field(name, value)

        {email_acc, type_acc, [normalized | acc]}
      end)

    %{
      ticket_code: Map.get(ticket_data, "ticket_code"),
      first_name: Map.get(ticket_data, "first_name"),
      last_name: Map.get(ticket_data, "last_name"),
      email: email,
      ticket_type: ticket_type || Map.get(ticket_data, "ticket_type"),
      allowed_checkins: Map.get(ticket_data, "allowed_checkins") || Map.get(ticket_data, "checkin_limit"),
      custom_fields: Enum.reverse(custom_map)
    }
  end

  def parse_attendee(ticket_data), do: %{}

  defp email_from_field(nil, _value), do: nil
  defp email_from_field(name, value) do
    if String.match?(String.downcase(to_string(name)), ~r/email/) do
      value
    else
      nil
    end
  end

  defp ticket_type_from_field(nil, _value), do: nil
  defp ticket_type_from_field(name, value) do
    if String.match?(String.downcase(to_string(name)), ~r/ticket/) do
      value
    else
      nil
    end
  end

  defp do_fetch_attendees(_site_url, _api_key, _per_page, page, total_pages, _callback, acc)
       when page > total_pages do
    {:ok, Enum.reverse(acc)}
  end

  defp do_fetch_attendees(site_url, api_key, per_page, page, total_pages, callback, acc) do
    :timer.sleep(@pagination_delay)

    case get_tickets_info(site_url, api_key, per_page, page) do
      {:ok, %{"data" => data}} ->
        parsed = Enum.map(data, &parse_attendee/1)
        maybe_callback(callback, page, total_pages, length(data))
        new_acc = Enum.reduce(parsed, acc, fn attendee, acc -> [attendee | acc] end)
        do_fetch_attendees(site_url, api_key, per_page, page + 1, total_pages, callback, new_acc)

      {:error, reason} ->
        {:error, reason, Enum.reverse(acc)}

      other ->
        {:error, "HTTP error: unexpected response #{inspect(other)}", Enum.reverse(acc)}
    end
  end

  defp maybe_callback(nil, _page, _total_pages, _count), do: :ok

  defp maybe_callback(callback, page, total_pages, count) when is_function(callback, 3) do
    try do
      callback.(page, total_pages, count)
    rescue
      exception ->
        Logger.warning("Tickera callback failed: #{Exception.message(exception)}")
        :error
    end
  end

  defp build_url(site_url, api_key, endpoint) do
    trimmed = site_url |> to_string() |> String.trim_trailing("/")
    endpoint = endpoint |> to_string() |> String.trim_leading("/")
    "#{trimmed}/tc-api/#{api_key}/#{endpoint}"
  end

  defp fetch_json(url) do
    Logger.debug("TickeraClient GET #{url}")

    try do
      headers = [{"accept", "application/json"}]
      options = [timeout: @timeout, recv_timeout: @timeout]

      case HTTPoison.get(url, headers, options) do
        {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in 200..299 ->
          case Jason.decode(body) do
            {:ok, data} -> {:ok, data}
            {:error, error} ->
              Logger.error("Failed to decode Tickera response: #{inspect(error)}")
              {:error, "HTTP error: invalid JSON response"}
          end

        {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
          Logger.error("Tickera request failed (status #{code}): #{body}")
          {:error, "HTTP error: status #{code}"}

        {:error, %HTTPoison.Error{reason: reason}} ->
          Logger.error("Tickera request error: #{inspect(reason)}")
          {:error, "HTTP error: #{inspect(reason)}"}
      end
    rescue
      exception ->
        Logger.error("Tickera request exception: #{Exception.message(exception)}")
        {:error, "HTTP error: #{Exception.message(exception)}"}
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(<<>>), do: nil

  defp parse_datetime(datetime_string) when is_binary(datetime_string) do
    trimmed = String.trim(datetime_string)

    cond do
      trimmed == "" -> nil
      true ->
        with {:ok, datetime, _offset} <- DateTime.from_iso8601(trimmed) do
          datetime
        else
          {:error, _} ->
            case NaiveDateTime.from_iso8601(trimmed) do
              {:ok, naive} ->
                case DateTime.from_naive(naive, "Etc/UTC") do
                  {:ok, datetime} -> datetime
                  _ -> naive
                end

              {:error, _} ->
                case Integer.parse(trimmed) do
                  {unix, ""} ->
                    case DateTime.from_unix(unix) do
                      {:ok, datetime} -> datetime
                      _ -> trimmed
                    end

                  _ -> trimmed
                end
            end
        end
    end
  end

  defp parse_datetime(other), do: other
end
