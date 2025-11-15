defmodule FastCheck.TickeraClient do
  @moduledoc """
  HTTP client responsible for communicating with the Tickera WordPress plugin API.
  """

  require Logger

  @timeout 30_000
  @pagination_delay 100
  @status_timeout 5_000
  @rate_limit_delay 100

  @ticket_defaults %{
    checksum: nil,
    ticket_code: nil,
    ticket_status: nil,
    ticket_type: nil,
    ticket_name: nil,
    allowed_checkins: 1,
    used_checkins: 0,
    remaining_checkins: 0,
    is_valid_now: false,
    can_enter: false,
    event_name: nil,
    event_start_date: nil,
    event_end_date: nil,
    first_checkin_at: nil,
    last_checkin_at: nil,
    occupancy_percentage: 0.0,
    purchaser_name: nil,
    purchaser_email: nil
  }

  @ticket_key_mapping %{
    "checksum" => :checksum,
    "ticket_code" => :ticket_code,
    "ticket_status" => :ticket_status,
    "ticket_type" => :ticket_type,
    "ticket_name" => :ticket_name,
    "allowed_checkins" => :allowed_checkins,
    "checkins" => :used_checkins,
    "used_checkins" => :used_checkins,
    "checked_in" => :used_checkins,
    "remaining_checkins" => :remaining_checkins,
    "event_name" => :event_name,
    "event_start_date" => :event_start_date,
    "event_end_date" => :event_end_date,
    "first_checkin_at" => :first_checkin_at,
    "last_checkin_at" => :last_checkin_at,
    "is_valid_now" => :is_valid_now,
    "can_enter" => :can_enter,
    "occupancy_percentage" => :occupancy_percentage,
    "buyer_email" => :purchaser_email,
    "purchaser_email" => :purchaser_email,
    "buyer_first" => :buyer_first,
    "buyer_last" => :buyer_last
  }

  @integer_fields [:allowed_checkins, :used_checkins, :remaining_checkins]
  @float_fields [:occupancy_percentage]
  @date_fields [:event_start_date, :event_end_date, :first_checkin_at, :last_checkin_at]
  @boolean_fields [:is_valid_now, :can_enter]

  @occupancy_key_mapping %{
    "event_id" => :event_id,
    "event_name" => :event_name,
    "event_date_time" => :event_date_time,
    "total_capacity" => :total_capacity,
    "checked_in" => :checked_in,
    "remaining" => :remaining,
    "occupancy_percentage" => :occupancy_percentage,
    "capacity_status" => :capacity_status,
    "alerts" => :alerts,
    "per_entrance" => :per_entrance
  }

  @per_entrance_key_mapping %{
    "capacity" => :capacity,
    "checked_in" => :checked_in,
    "remaining" => :remaining,
    "occupancy_percentage" => :occupancy_percentage,
    "capacity_status" => :capacity_status,
    "alerts" => :alerts
  }

  @occupancy_integer_fields [:total_capacity, :checked_in, :remaining]
  @occupancy_float_fields [:occupancy_percentage]
  @per_entrance_integer_fields [:capacity, :checked_in, :remaining]
  @per_entrance_float_fields [:occupancy_percentage]
  @occupancy_default_capacity_status "unknown"

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
  Retrieves live event occupancy statistics from Tickera.

  Performs the authenticated request against `/tc-api/{api_key}/event_occupancy`,
  normalizes the response keys into atoms, and coerces the numeric fields into the
  expected integer/float representations.

  ## Returns
    * `{:ok, occupancy_map}` when Tickera responds successfully.
    * `{:error, code, message}` when HTTP or business errors occur.
  """
  @spec get_event_occupancy(String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t(), String.t()}
  def get_event_occupancy(site_url, api_key) do
    Logger.debug("TickeraClient: get_event_occupancy – START")
    :timer.sleep(@rate_limit_delay)

    url = build_url(site_url, api_key, "event_occupancy")

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"accept", "application/json"}
    ]

    options = [timeout: @status_timeout, recv_timeout: @status_timeout]

    case HTTPoison.get(url, headers, options) do
      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in 200..299 ->
        with {:ok, payload} <- decode_json_map(body),
             {:ok, normalized} <- normalize_event_occupancy(payload) do
          Logger.info("TickeraClient: get_event_occupancy – SUCCESS")
          {:ok, normalized}
        end

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        Logger.warn("TickeraClient: get_event_occupancy – AUTH_ERROR")
        {:error, "AUTH_ERROR", "Authentication failed"}

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        Logger.warn("TickeraClient: get_event_occupancy – NOT_FOUND")
        {:error, "NOT_FOUND", "Event occupancy not found"}

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        Logger.warn("TickeraClient: get_event_occupancy – RATE_LIMITED")
        {:error, "RATE_LIMITED", "Tickera rate limit reached"}

      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code >= 500 ->
        Logger.warn("TickeraClient: get_event_occupancy – SERVER_ERROR")
        {:error, "SERVER_ERROR", "Tickera returned status #{code}: #{body}"}

      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        Logger.error("Tickera event occupancy unexpected response (#{code}): #{body}")
        {:error, "HTTP_ERROR", "Unexpected HTTP status #{code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Tickera event occupancy request failed: #{inspect(reason)}")
        {:error, "HTTP_ERROR", "#{inspect(reason)}"}
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
  Retrieves the current Tickera ticket status payload, normalizing the response
  into the FastCheck structure.

  ## Returns
    * `{:ok, map()}` with detailed status information on success.
    * `{:error, code, message}` when Tickera reports business or HTTP errors.
  """
  @spec get_ticket_detailed_status(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t(), String.t()}
  def get_ticket_detailed_status(site_url, api_key, checksum) do
    Logger.debug("TickeraClient: get_ticket_detailed_status – START")
    :timer.sleep(@rate_limit_delay)

    url = build_url(site_url, api_key, "ticket_status/#{checksum}")

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"accept", "application/json"}
    ]

    options = [timeout: @status_timeout, recv_timeout: @status_timeout]

    case HTTPoison.get(url, headers, options) do
      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code in 200..299 ->
        with {:ok, payload} <- decode_ticket_status(body),
             {:ok, normalized} <- normalize_ticket_payload(payload) do
          Logger.info("TickeraClient: get_ticket_detailed_status – SUCCESS")
          {:ok, normalized}
        end

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        Logger.warn("TickeraClient: get_ticket_detailed_status – AUTH_ERROR")
        {:error, "AUTH_ERROR", "Authentication failed"}

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        Logger.warn("TickeraClient: get_ticket_detailed_status – NOT_FOUND")
        {:error, "NOT_FOUND", "Ticket not found"}

      {:ok, %HTTPoison.Response{status_code: 429}} ->
        Logger.warn("TickeraClient: get_ticket_detailed_status – RATE_LIMITED")
        {:error, "RATE_LIMITED", "Tickera rate limit reached"}

      {:ok, %HTTPoison.Response{status_code: code, body: body}} when code >= 500 ->
        Logger.warn("TickeraClient: get_ticket_detailed_status – SERVER_ERROR")
        {:error, "SERVER_ERROR", "Tickera returned status #{code}: #{body}"}

      {:ok, %HTTPoison.Response{status_code: code, body: body}} ->
        Logger.error("Tickera ticket status unexpected response (#{code}): #{body}")
        {:error, "HTTP_ERROR", "Unexpected HTTP status #{code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Tickera ticket status request failed: #{inspect(reason)}")
        {:error, "HTTP_ERROR", "#{inspect(reason)}"}
    end
  end

  @doc """
  Fetches all attendees by iterating through every results page.

  An optional `callback` function can be provided. It is invoked for each page with
  `(page_number, total_pages, count_for_page)`.

  ## Returns
    * `{:ok, attendees, total_count}` on full success.
    * `{:error, reason, partial_attendees}` if any request fails.
  """
  @spec fetch_all_attendees(
          String.t(),
          String.t(),
          pos_integer(),
          (pos_integer(), pos_integer(), non_neg_integer() -> any()) | nil
        ) ::
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
      allowed_checkins:
        Map.get(ticket_data, "allowed_checkins") || Map.get(ticket_data, "checkin_limit"),
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

  defp decode_ticket_status(body) do
    case Jason.decode(body) do
      {:ok, %{} = payload} ->
        {:ok, payload}

      {:ok, _other} ->
        Logger.error("Tickera ticket status response was not a JSON object")
        {:error, "JSON_ERROR", "Response not valid JSON"}

      {:error, _error} ->
        Logger.error("Tickera ticket status response was not valid JSON")
        {:error, "JSON_ERROR", "Response not valid JSON"}
    end
  end

  defp decode_json_map(body) do
    case Jason.decode(body) do
      {:ok, %{} = payload} ->
        {:ok, payload}

      {:ok, _other} ->
        Logger.error("Tickera event occupancy response was not a JSON object")
        {:error, "JSON_ERROR", "Response not valid JSON"}

      {:error, _error} ->
        Logger.error("Tickera event occupancy response was not valid JSON")
        {:error, "JSON_ERROR", "Response not valid JSON"}
    end
  end

  defp normalize_ticket_payload(%{} = payload) do
    case extract_business_error(payload) do
      {:error, code, message} ->
        Logger.warn("TickeraClient: get_ticket_detailed_status – #{code}")
        {:error, code, message}

      :ok ->
        data_map =
          payload
          |> Map.get("data")
          |> case do
            %{} = inner -> inner
            _ -> Map.get(payload, "ticket")
          end
          |> case do
            %{} = inner -> inner
            _ -> payload
          end

        normalized =
          Enum.reduce(data_map, %{}, fn {key, value}, acc ->
            maybe_put_ticket_field(acc, key, value)
          end)
          |> ensure_purchaser_fields()
          |> ensure_remaining_checkins()

        {:ok, Map.merge(@ticket_defaults, normalized, fn _key, _left, right -> right end)}
    end
  end

  defp normalize_ticket_payload(_payload) do
    Logger.error("Tickera ticket status payload missing")
    {:error, "JSON_ERROR", "Response not valid JSON"}
  end

  defp normalize_event_occupancy(%{} = payload) do
    case extract_business_error(payload) do
      {:error, code, message} ->
        Logger.warn("TickeraClient: get_event_occupancy – #{code}")
        {:error, code, message}

      :ok ->
        data_map = Map.get(payload, "data")
        source = if is_map(data_map), do: data_map, else: payload

        normalized =
          Enum.reduce(source, %{}, fn {key, value}, acc ->
            maybe_put_occupancy_field(acc, key, value)
          end)
          |> ensure_capacity_status_default()
          |> ensure_alerts_default()
          |> Map.put_new(:per_entrance, %{})

        {:ok, normalized}
    end
  end

  defp normalize_event_occupancy(_payload) do
    Logger.error("Tickera event occupancy payload missing")
    {:error, "JSON_ERROR", "Response not valid JSON"}
  end

  defp extract_business_error(payload) when is_map(payload) do
    cond do
      is_binary(Map.get(payload, "error_code")) ->
        code = Map.get(payload, "error_code")

        message =
          Map.get(payload, "description") || Map.get(payload, "message") || "Tickera error"

        {:error, code, message}

      is_binary(Map.get(payload, "error")) ->
        code = Map.get(payload, "error")

        message =
          Map.get(payload, "description") || Map.get(payload, "message") || "Tickera error"

        {:error, code, message}

      Map.get(payload, "pass") == false ->
        code = Map.get(payload, "error_code") || Map.get(payload, "error") || "INVALID_TICKET"

        message =
          Map.get(payload, "description") || Map.get(payload, "message") || "Ticket invalid"

        {:error, code, message}

      true ->
        :ok
    end
  end

  defp extract_business_error(_payload), do: :ok

  defp maybe_put_ticket_field(acc, key, value) when is_binary(key) do
    case Map.get(@ticket_key_mapping, key) do
      nil -> acc
      atom_key -> Map.put(acc, atom_key, normalize_value(atom_key, value))
    end
  end

  defp maybe_put_ticket_field(acc, _key, _value), do: acc

  defp maybe_put_occupancy_field(acc, key, value) when is_binary(key) do
    case Map.get(@occupancy_key_mapping, key) do
      nil -> acc
      :per_entrance -> Map.put(acc, :per_entrance, normalize_per_entrance(value))
      atom_key -> Map.put(acc, atom_key, normalize_occupancy_value(atom_key, value))
    end
  end

  defp maybe_put_occupancy_field(acc, key, value) when is_atom(key) do
    maybe_put_occupancy_field(acc, Atom.to_string(key), value)
  end

  defp maybe_put_occupancy_field(acc, _key, _value), do: acc

  defp maybe_put_per_entrance_field(acc, key, value) when is_binary(key) do
    case Map.get(@per_entrance_key_mapping, key) do
      nil -> acc
      atom_key -> Map.put(acc, atom_key, normalize_per_entrance_value(atom_key, value))
    end
  end

  defp maybe_put_per_entrance_field(acc, key, value) when is_atom(key) do
    maybe_put_per_entrance_field(acc, Atom.to_string(key), value)
  end

  defp maybe_put_per_entrance_field(acc, _key, _value), do: acc

  defp normalize_value(key, value) when key in @integer_fields, do: coerce_integer(value)
  defp normalize_value(key, value) when key in @float_fields, do: coerce_float(value)
  defp normalize_value(key, value) when key in @date_fields, do: coerce_date(value)
  defp normalize_value(key, value) when key in @boolean_fields, do: coerce_boolean(value)
  defp normalize_value(_key, value), do: value

  defp normalize_occupancy_value(key, value) when key in @occupancy_integer_fields,
    do: coerce_integer(value)

  defp normalize_occupancy_value(key, value) when key in @occupancy_float_fields,
    do: coerce_float(value)

  defp normalize_occupancy_value(:event_date_time, value), do: parse_datetime(value)
  defp normalize_occupancy_value(:alerts, value), do: coerce_alerts(value)
  defp normalize_occupancy_value(_key, value), do: value

  defp normalize_per_entrance_value(key, value) when key in @per_entrance_integer_fields,
    do: coerce_integer(value)

  defp normalize_per_entrance_value(key, value) when key in @per_entrance_float_fields,
    do: coerce_float(value)

  defp normalize_per_entrance_value(:alerts, value), do: coerce_alerts(value)
  defp normalize_per_entrance_value(_key, value), do: value

  defp coerce_integer(value) when is_integer(value), do: value
  defp coerce_integer(value) when is_float(value), do: trunc(value)

  defp coerce_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> 0
    end
  end

  defp coerce_integer(_value), do: 0

  defp coerce_float(value) when is_float(value), do: value
  defp coerce_float(value) when is_integer(value), do: value / 1

  defp coerce_float(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp coerce_float(_value), do: 0.0

  defp coerce_date(value) when is_binary(value) do
    value
    |> String.trim()
    |> Date.from_iso8601()
    |> case do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp coerce_date(%Date{} = date), do: date
  defp coerce_date(_value), do: nil

  defp coerce_boolean(value) when is_boolean(value), do: value
  defp coerce_boolean(value) when is_integer(value), do: value != 0

  defp coerce_boolean(value) when is_binary(value) do
    value
    |> String.downcase()
    |> case do
      "true" -> true
      "1" -> true
      "yes" -> true
      _ -> false
    end
  end

  defp coerce_boolean(_value), do: false

  defp coerce_alerts(value) when is_list(value) do
    Enum.map(value, &to_string/1)
  end

  defp coerce_alerts(value) when is_binary(value), do: [value]
  defp coerce_alerts(nil), do: []
  defp coerce_alerts(value), do: List.wrap(value)

  defp ensure_purchaser_fields(map) do
    name =
      [Map.get(map, :buyer_first), Map.get(map, :buyer_last)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
      |> case do
        "" -> Map.get(map, :purchaser_name)
        other -> other
      end

    map
    |> Map.put(:purchaser_name, name)
    |> Map.delete(:buyer_first)
    |> Map.delete(:buyer_last)
  end

  defp ensure_remaining_checkins(map) do
    allowed = Map.get(map, :allowed_checkins, 1) || 1
    used = Map.get(map, :used_checkins, 0) || 0

    remaining =
      map
      |> Map.get(:remaining_checkins)
      |> case do
        nil -> max(allowed - used, 0)
        value -> value
      end

    Map.put(map, :allowed_checkins, allowed)
    |> Map.put(:used_checkins, used)
    |> Map.put(:remaining_checkins, remaining)
  end

  defp ensure_capacity_status_default(map) do
    Map.put_new(map, :capacity_status, @occupancy_default_capacity_status)
  end

  defp ensure_alerts_default(map) do
    Map.put_new(map, :alerts, [])
  end

  defp normalize_per_entrance(per_entrance) when is_map(per_entrance) do
    Enum.reduce(per_entrance, %{}, fn {entrance, stats}, acc ->
      normalized =
        stats
        |> ensure_map()
        |> Enum.reduce(%{}, fn {key, value}, inner ->
          maybe_put_per_entrance_field(inner, key, value)
        end)
        |> ensure_capacity_status_default()
        |> ensure_alerts_default()

      Map.put(acc, to_string(entrance), normalized)
    end)
  end

  defp normalize_per_entrance(_per_entrance), do: %{}

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

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
            {:ok, data} ->
              {:ok, data}

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
      trimmed == "" ->
        nil

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

                  _ ->
                    trimmed
                end
            end
        end
    end
  end

  defp parse_datetime(other), do: other
end
