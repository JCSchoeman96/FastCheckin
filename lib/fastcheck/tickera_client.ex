defmodule FastCheck.TickeraClient do
  @moduledoc """
  HTTP client responsible for communicating with the Tickera WordPress plugin API.
  """

  require Logger
  alias FastCheck.TickeraClient.Fallback
  alias Req.Response
  alias Req.TransportError

  @timeout 30_000
  @pagination_delay 100
  @status_timeout 5_000
  @rate_limit_delay 100
  @request_fun Application.compile_env(:fastcheck, :tickera_request_fun, &Req.request/1)
  @tickera_user_agent "FastCheck/1.0 (+https://scan.voelgoed.co.za)"

  @doc """
  Fetches the historical check-in events for a ticket checksum.

  Performs a Bearer authenticated GET request against
  `/tc-api/{api_key}/ticket_check_in_history/{checksum}?limit={limit}` with a
  5-second timeout and 100 ms safety delay before issuing the request.

  Returns each record normalized with parsed `Date`/`Time` entries when
  possible, defaulting to `nil` when values are missing or malformed.
  """
  @spec fetch_check_in_history(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, list()} | {:error, String.t(), String.t()}
  def fetch_check_in_history(site_url, api_key, checksum, limit \\ 100) do
    Logger.debug("TickeraClient: fetch_check_in_history – START")
    :timer.sleep(@rate_limit_delay)

    limit = max(1, limit)

    endpoint = "ticket_check_in_history/#{checksum}?limit=#{limit}"
    url = build_url(site_url, api_key, endpoint)

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"accept", "application/json"}
    ]

    case request(:get, url,
           headers: headers,
           connect_timeout: 5_000,
           receive_timeout: 5_000
         ) do
      {:ok, %Response{status: code, body: body}} when code in 200..299 ->
        with {:ok, records} <- decode_check_in_history(body) do
          Logger.info("TickeraClient: fetch_check_in_history – SUCCESS")
          {:ok, records}
        end

      {:ok, %Response{status: 401}} ->
        Logger.warning("TickeraClient: fetch_check_in_history – AUTH_ERROR")
        {:error, "AUTH_ERROR", "Authentication failed"}

      {:ok, %Response{status: 404}} ->
        Logger.warning("TickeraClient: fetch_check_in_history – NOT_FOUND")
        {:error, "NOT_FOUND", "Check-in history not found"}

      {:ok, %Response{status: 429}} ->
        Logger.warning("TickeraClient: fetch_check_in_history – RATE_LIMITED")
        {:error, "RATE_LIMITED", "Tickera rate limit reached"}

      {:ok, %Response{status: code, body: body}} when code >= 500 ->
        Logger.warning("TickeraClient: fetch_check_in_history – SERVER_ERROR")
        {:error, "SERVER_ERROR", "Tickera returned status #{code}: #{body}"}

      {:ok, %Response{status: code, body: body}} ->
        Logger.error("Tickera check-in history unexpected response (#{code}): #{body}")
        {:error, "HTTP_ERROR", "Unexpected HTTP status #{code}"}

      {:error, error} ->
        Logger.error("Tickera check-in history request failed: #{inspect(error)}")
        {:error, "HTTP_ERROR", "#{inspect(error)}"}
    end
  end

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
  @advanced_business_errors [
    "INVALID_TICKET",
    "ALREADY_SCANNED_TODAY",
    "LIMIT_EXCEEDED",
    "OUTSIDE_WINDOW",
    "VENUE_FULL",
    "NOT_INSIDE"
  ]

  @advanced_key_mapping %{
    "ticket_code" => :ticket_code,
    "check_in_type" => :check_in_type,
    "entrance_name" => :entrance_name,
    "operator_name" => :operator_name,
    "used_checkins" => :used_checkins,
    "used_check_ins" => :used_checkins,
    "remaining_checkins" => :remaining_checkins,
    "remaining_check_ins" => :remaining_checkins,
    "allowed_checkins" => :allowed_checkins,
    "allowed_check_ins" => :allowed_checkins,
    "can_reenter" => :can_reenter,
    "message" => :message,
    "description" => :description,
    "status" => :status,
    "check_in_timestamp" => :check_in_timestamp,
    "timestamp" => :timestamp
  }

  @advanced_integer_fields [:allowed_checkins, :used_checkins, :remaining_checkins]
  @advanced_boolean_fields [:can_reenter]
  @advanced_string_fields [
    :ticket_code,
    :check_in_type,
    :entrance_name,
    :operator_name,
    :message,
    :description,
    :status,
    :timestamp,
    :check_in_timestamp
  ]

  @ticket_config_key_mapping %{
    "allowed_checkins" => :allowed_checkins,
    "allow_reentry" => :allow_reentry,
    "allowed_entrances" => :allowed_entrances,
    "check_in_window_buffer_minutes" => :check_in_window_buffer_minutes,
    "check_in_window_days" => :check_in_window_days,
    "check_in_window_end" => :check_in_window_end,
    "check_in_window_start" => :check_in_window_start,
    "check_in_window_timezone" => :check_in_window_timezone,
    "check_in_window_type" => :check_in_window_type,
    "currency" => :currency,
    "daily_check_in_limit" => :daily_check_in_limit,
    "description" => :description,
    "entrance_limit" => :entrance_limit,
    "event_id" => :event_id,
    "event_name" => :event_name,
    "limit_per_order" => :limit_per_order,
    "max_per_order" => :max_per_order,
    "message" => :message,
    "min_per_order" => :min_per_order,
    "pass" => :pass,
    "price" => :price,
    "status" => :status,
    "ticket_name" => :ticket_name,
    "ticket_title" => :ticket_title,
    "ticket_type" => :ticket_type,
    "ticket_type_id" => :ticket_type_id
  }

  @ticket_config_integer_fields [
    :allowed_checkins,
    :check_in_window_buffer_minutes,
    :check_in_window_days,
    :daily_check_in_limit,
    :entrance_limit,
    :event_id,
    :limit_per_order,
    :max_per_order,
    :min_per_order,
    :ticket_type_id
  ]

  @ticket_config_float_fields [:price]
  @ticket_config_boolean_fields [:allow_reentry, :pass]
  @ticket_config_date_fields [:check_in_window_start, :check_in_window_end]

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

  The returned map includes the event name, start/end timestamps, and ticket statistics. The
  `"event_date_time"`, `"event_start_date"`, and `"event_end_date"` fields are normalized to
  a `DateTime`/`NaiveDateTime` when possible via `parse_datetime/1`.

  ## Returns
    * `{:ok, response_map}` on success.
    * `{:error, reason}` on failure.
  """
  @spec get_event_essentials(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def get_event_essentials(site_url, api_key) do
    url = build_url(site_url, api_key, "event_essentials")

    with {:ok, data} <- fetch_json(url) do
      normalized =
        data
        |> Map.update("event_date_time", nil, &parse_datetime/1)
        |> Map.update("event_start_date", nil, &parse_datetime/1)
        |> Map.update("event_end_date", nil, &parse_datetime/1)

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

    case request(:get, url,
           headers: headers,
           connect_timeout: @status_timeout,
           receive_timeout: @status_timeout
         ) do
      {:ok, %Response{status: code, body: body}} when code in 200..299 ->
        with {:ok, payload} <- decode_json_map(body),
             {:ok, normalized} <- normalize_event_occupancy(payload) do
          Logger.info("TickeraClient: get_event_occupancy – SUCCESS")
          {:ok, normalized}
        end

      {:ok, %Response{status: 401}} ->
        Logger.warning("TickeraClient: get_event_occupancy – AUTH_ERROR")
        {:error, "AUTH_ERROR", "Authentication failed"}

      {:ok, %Response{status: 404}} ->
        Logger.warning("TickeraClient: get_event_occupancy – NOT_FOUND")
        {:error, "NOT_FOUND", "Event occupancy not found"}

      {:ok, %Response{status: 429}} ->
        Logger.warning("TickeraClient: get_event_occupancy – RATE_LIMITED")
        {:error, "RATE_LIMITED", "Tickera rate limit reached"}

      {:ok, %Response{status: code, body: body}} when code >= 500 ->
        Logger.warning("TickeraClient: get_event_occupancy – SERVER_ERROR")
        {:error, "SERVER_ERROR", "Tickera returned status #{code}: #{body}"}

      {:ok, %Response{status: code, body: body}} ->
        Logger.error("Tickera event occupancy unexpected response (#{code}): #{body}")
        {:error, "HTTP_ERROR", "Unexpected HTTP status #{code}"}

      {:error, error} ->
        Logger.error("Tickera event occupancy request failed: #{inspect(error)}")
        {:error, "HTTP_ERROR", "#{inspect(error)}"}
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

    case request(:get, url,
           headers: headers,
           connect_timeout: @status_timeout,
           receive_timeout: @status_timeout
         ) do
      {:ok, %Response{status: code, body: body}} when code in 200..299 ->
        with {:ok, payload} <- decode_ticket_status(body),
             {:ok, normalized} <- normalize_ticket_payload(payload) do
          Logger.info("TickeraClient: get_ticket_detailed_status – SUCCESS")
          {:ok, normalized}
        end

      {:ok, %Response{status: 401}} ->
        Logger.warning("TickeraClient: get_ticket_detailed_status – AUTH_ERROR")
        {:error, "AUTH_ERROR", "Authentication failed"}

      {:ok, %Response{status: 404}} ->
        Logger.warning("TickeraClient: get_ticket_detailed_status – NOT_FOUND")
        {:error, "NOT_FOUND", "Ticket not found"}

      {:ok, %Response{status: 429}} ->
        Logger.warning("TickeraClient: get_ticket_detailed_status – RATE_LIMITED")
        {:error, "RATE_LIMITED", "Tickera rate limit reached"}

      {:ok, %Response{status: code, body: body}} when code >= 500 ->
        Logger.warning("TickeraClient: get_ticket_detailed_status – SERVER_ERROR")
        {:error, "SERVER_ERROR", "Tickera returned status #{code}: #{body}"}

      {:ok, %Response{status: code, body: body}} ->
        Logger.error("Tickera ticket status unexpected response (#{code}): #{body}")
        {:error, "HTTP_ERROR", "Unexpected HTTP status #{code}"}

      {:error, error} ->
        Logger.error("Tickera ticket status request failed: #{inspect(error)}")
        {:error, "HTTP_ERROR", "#{inspect(error)}"}
    end
  end

  @doc """
  Retrieves the configuration for a Tickera ticket type.

  Adds a 100 ms safety delay, authenticates via Bearer header, and performs a
  GET request against `/tc-api/{api_key}/ticket_type_config/{ticket_type_id}`.
  The JSON body is decoded with snake_case keys converted to atoms, numeric
  fields coerced to integers/floats, and `check_in_window_start`/`end` parsed as
  `Date` structs when provided. Missing `allowed_checkins` defaults to `1`.

  ## Returns
    * `{:ok, config_map}` when Tickera responds successfully.
    * `{:error, code, message}` when HTTP or business errors are reported.
  """
  @spec get_ticket_config(String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, String.t(), String.t()}
  def get_ticket_config(site_url, api_key, ticket_type_id)
      when is_integer(ticket_type_id) and ticket_type_id > 0 do
    Logger.debug("TickeraClient: get_ticket_config – START")
    :timer.sleep(@rate_limit_delay)

    url = build_url(site_url, api_key, "ticket_type_config/#{ticket_type_id}")

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"accept", "application/json"}
    ]

    case request(:get, url,
           headers: headers,
           connect_timeout: @status_timeout,
           receive_timeout: @status_timeout
         ) do
      {:ok, %Response{status: code, body: body}} when code in 200..299 ->
        with {:ok, payload} <- decode_json_map(body),
             {:ok, config} <- normalize_ticket_config(payload) do
          Logger.info("TickeraClient: get_ticket_config – SUCCESS")
          {:ok, config}
        end

      {:ok, %Response{status: 401}} ->
        Logger.warning("TickeraClient: get_ticket_config – AUTH_ERROR")
        {:error, "AUTH_ERROR", "Authentication failed"}

      {:ok, %Response{status: 404}} ->
        Logger.warning("TickeraClient: get_ticket_config – NOT_FOUND")
        {:error, "NOT_FOUND", "Ticket type config not found"}

      {:ok, %Response{status: 429}} ->
        Logger.warning("TickeraClient: get_ticket_config – RATE_LIMITED")
        {:error, "RATE_LIMITED", "Tickera rate limit reached"}

      {:ok, %Response{status: code, body: body}} when code >= 500 ->
        Logger.warning("TickeraClient: get_ticket_config – SERVER_ERROR")
        {:error, "SERVER_ERROR", "Tickera returned status #{code}: #{body}"}

      {:ok, %Response{status: code, body: body}} ->
        Logger.error("Tickera ticket config unexpected response (#{code}): #{body}")
        {:error, "HTTP_ERROR", "Unexpected HTTP status #{code}"}

      {:error, error} ->
        Logger.error("Tickera ticket config request failed: #{inspect(error)}")
        {:error, "HTTP_ERROR", "#{inspect(error)}"}
    end
  end

  def get_ticket_config(site_url, api_key, ticket_type_id) when is_binary(ticket_type_id) do
    case Integer.parse(ticket_type_id) do
      {value, _rest} when value > 0 ->
        get_ticket_config(site_url, api_key, value)

      _ ->
        Logger.warning(
          "TickeraClient: get_ticket_config – INVALID_TICKET_TYPE_ID #{inspect(ticket_type_id)}"
        )

        {:error, "INVALID_TICKET_TYPE_ID", "Ticket type id must be positive"}
    end
  end

  def get_ticket_config(_site_url, _api_key, ticket_type_id) do
    Logger.warning(
      "TickeraClient: get_ticket_config – INVALID_TICKET_TYPE_ID #{inspect(ticket_type_id)}"
    )

    {:error, "INVALID_TICKET_TYPE_ID", "Ticket type id must be positive"}
  end

  @doc """
  Submits an advanced Tickera check-in using the scanner metadata.

  Sends a POST request to `/tc-api/{api_key}/check_in_advanced`, including the
  ticket code, check-in type, entrance/operator names, and a UTC timestamp.

  ## Parameters
    * `site_url` - Base URL of the Tickera site.
    * `api_key` - Tickera API key used for authentication.
    * `ticket_code` - Unique ticket identifier to check in.
    * `check_in_type` - The check-in type (scan/manual/etc).
    * `entrance_name` - Entrance/door name performing the check-in.
    * `operator_name` - Optional operator handling the scan.

  ## Returns
    * `{:ok, response_map}` when the request succeeds.
    * `{:error, code, message}` for business, HTTP, or network failures.
  """
  @spec submit_advanced_check_in(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil
        ) :: {:ok, map()} | {:error, String.t(), String.t()}
  def submit_advanced_check_in(
        site_url,
        api_key,
        ticket_code,
        check_in_type,
        entrance_name,
        operator_name
      ) do
    :timer.sleep(100)

    url = build_url(site_url, api_key, "check_in_advanced")

    payload = %{
      ticket_code: ticket_code,
      check_in_type: check_in_type,
      entrance_name: entrance_name,
      operator_name: operator_name,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    case request(:post, url,
           headers: headers,
           body: Jason.encode!(payload),
           connect_timeout: 5_000,
           receive_timeout: 5_000
         ) do
      {:ok, %Response{status: code, body: body}} when code in 200..299 ->
        with {:ok, decoded} <- decode_json_map(body),
             {:ok, normalized} <- normalize_advanced_check_in(decoded) do
          Logger.info("TickeraClient: submit_advanced_check_in – SUCCESS")
          {:ok, normalized}
        end

      {:ok, %Response{status: code, body: body}} when code >= 500 ->
        Logger.error(
          "TickeraClient: submit_advanced_check_in HTTP #{code} – #{String.slice(body || "", 0, 200)}"
        )

        {:error, "HTTP_#{code}", "Tickera returned status #{code}"}

      {:ok, %Response{status: code, body: body}} ->
        Logger.error(
          "TickeraClient: submit_advanced_check_in HTTP #{code} – #{String.slice(body || "", 0, 200)}"
        )

        {:error, "HTTP_#{code}", "Tickera returned status #{code}"}

      {:error, error} ->
        handle_advanced_network_error(error)
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
      {:ok, first_resp} ->
        {data, additional} = extract_tickets_page(first_resp)
        total_count = extract_results_count(additional, data)

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
          {:fallback, cached, count} -> {:ok, cached, count}
          {:error, reason, partial} -> {:error, reason, partial}
        end

      {:error, reason} ->
        case handle_attendee_fallback(site_url, api_key, reason) do
          {:fallback, cached, count} -> {:ok, cached, count}
          other -> other
        end

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
    ticket_data = extract_ticket_data(ticket_data)

    custom_fields =
      ticket_data
      |> Map.get("custom_fields", Map.get(ticket_data, :custom_fields, []))
      |> normalize_custom_fields()

    {email, ticket_type, custom_map} =
      Enum.reduce(custom_fields, {nil, nil, %{}}, fn {name, value}, {email_acc, type_acc, acc} ->
        normalized_name = normalize_custom_field_name(name)
        normalized_value = normalize_custom_field_value(value)

        email_acc = email_acc || email_from_field(normalized_name, normalized_value)
        type_acc = type_acc || ticket_type_from_field(normalized_name, normalized_value)

        updated_acc =
          if is_binary(normalized_name) and normalized_name != "" do
            Map.put(acc, normalized_name, normalized_value)
          else
            acc
          end

        {email_acc, type_acc, updated_acc}
      end)

    allowed_checkins =
      Map.get(ticket_data, "allowed_checkins") ||
        Map.get(ticket_data, :allowed_checkins) ||
        Map.get(ticket_data, "checkin_limit")

    checkins_used =
      Map.get(ticket_data, "checkins") ||
        Map.get(ticket_data, :checkins) ||
        Map.get(ticket_data, "checked_in_count") ||
        Map.get(ticket_data, :checked_in_count)

    used_count = normalize_non_negative_int(checkins_used)
    allowed_count = normalize_non_negative_int(allowed_checkins)

    remaining_checkins =
      case {allowed_count, used_count} do
        {a, u} when is_integer(a) and a > 0 and is_integer(u) -> max(a - u, 0)
        _ -> nil
      end

    checked_in_flag =
      normalize_checked_in_flag(
        Map.get(ticket_data, "checked-in") ||
          Map.get(ticket_data, :checked_in) ||
          Map.get(ticket_data, "checked_in")
      )

    checkouts_count =
      Map.get(ticket_data, "check-outs") ||
        Map.get(ticket_data, :check_outs) ||
        Map.get(ticket_data, "check_outs")
        |> normalize_non_negative_int()

    payment_status =
      pick_field(ticket_data, [
        "order_status",
        :order_status,
        "payment_status",
        :payment_status,
        "status",
        :status
      ])

    buyer_first =
      pick_field(ticket_data, ["buyer_first", :buyer_first, "purchaser_first", :purchaser_first])

    buyer_last =
      pick_field(ticket_data, ["buyer_last", :buyer_last, "purchaser_last", :purchaser_last])

    buyer_email =
      pick_field(ticket_data, ["buyer_email", :buyer_email, "purchaser_email", :purchaser_email]) ||
        find_custom_field_value(custom_map, [~r/(buyer|purchaser).*(e-?mail|email)/i])

    attendee_first =
      pick_field(ticket_data, [
        "first_name",
        :first_name,
        "attendee_first_name",
        :attendee_first_name,
        "ticket_holder_first_name",
        :ticket_holder_first_name
      ]) ||
        find_custom_field_value(
          custom_map,
          [~r/(attendee|ticket ?holder).*(first|name)/i, ~r/\b(first name|voornaam)\b/i],
          [~r/(buyer|purchaser|billing|besteller)/i]
        ) ||
        buyer_first

    attendee_last =
      pick_field(ticket_data, [
        "last_name",
        :last_name,
        "attendee_last_name",
        :attendee_last_name,
        "ticket_holder_last_name",
        :ticket_holder_last_name
      ]) ||
        find_custom_field_value(
          custom_map,
          [
            ~r/(attendee|ticket ?holder).*(last|surname|family)/i,
            ~r/\b(last name|surname|van)\b/i
          ],
          [~r/(buyer|purchaser|billing|besteller)/i]
        ) ||
        buyer_last

    attendee_email =
      pick_field(ticket_data, [
        "email",
        :email,
        "attendee_email",
        :attendee_email,
        "ticket_holder_email",
        :ticket_holder_email
      ]) ||
        find_custom_field_value(
          custom_map,
          [~r/(attendee|ticket ?holder).*(e-?mail|email)/i, ~r/\b(e-?mail|email)\b/i],
          [~r/(buyer|purchaser|billing|besteller)/i]
        ) ||
        email ||
        buyer_email

    custom_map =
      custom_map
      |> put_if_present("buyer_first", buyer_first)
      |> put_if_present("buyer_last", buyer_last)
      |> put_if_present("buyer_email", buyer_email)
      |> put_if_present("checked_in_flag", checked_in_flag)
      |> put_if_present("checkins_used", used_count)
      |> put_if_present("checkouts_count", checkouts_count)

    %{
      ticket_code:
        Map.get(ticket_data, "ticket_code") ||
          Map.get(ticket_data, :ticket_code) ||
          Map.get(ticket_data, "checksum") ||
          Map.get(ticket_data, :checksum),
      first_name: attendee_first,
      last_name: attendee_last,
      email: attendee_email,
      ticket_type_id:
        ticket_data
        |> Map.get("ticket_type_id")
        |> case do
          nil -> Map.get(ticket_data, :ticket_type_id)
          id -> id
        end
        |> normalize_ticket_type_id_field(),
      ticket_type:
        ticket_type ||
          Map.get(ticket_data, "ticket_type") ||
          Map.get(ticket_data, :ticket_type),
      allowed_checkins: allowed_checkins,
      checkins_remaining: remaining_checkins,
      payment_status: payment_status,
      custom_fields: custom_map
    }
  end

  def parse_attendee(_ticket_data), do: %{}

  defp email_from_field(nil, _value), do: nil

  defp email_from_field(name, value) do
    if String.match?(String.downcase(to_string(name)), ~r/email/) do
      value
    else
      nil
    end
  end

  defp normalize_ticket_type_id_field(value) do
    value
    |> coerce_integer()
    |> case do
      number when number > 0 -> number
      _ -> nil
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
      {:ok, response} ->
        {data, _additional} = extract_tickets_page(response)
        parsed = Enum.map(data, &parse_attendee/1)
        maybe_callback(callback, page, total_pages, length(data))
        new_acc = Enum.reduce(parsed, acc, fn attendee, acc -> [attendee | acc] end)
        do_fetch_attendees(site_url, api_key, per_page, page + 1, total_pages, callback, new_acc)

      {:error, reason} ->
        handle_attendee_fallback(site_url, api_key, reason, Enum.reverse(acc))

      other ->
        {:error, "HTTP error: unexpected response #{inspect(other)}", Enum.reverse(acc)}
    end
  end

  defp extract_tickets_page(%{} = response) do
    data =
      case Map.get(response, "data", Map.get(response, :data)) do
        list when is_list(list) -> list
        %{} = map -> [map]
        _ -> []
      end

    additional = Map.get(response, "additional", Map.get(response, :additional, %{}))
    {Enum.map(data, &extract_ticket_data/1), additional}
  end

  defp extract_tickets_page(response) when is_list(response) do
    Enum.reduce(response, {[], %{}}, fn item, {acc_data, acc_additional} ->
      cond do
        is_map(item) and is_map(Map.get(item, "data")) ->
          data_map = Map.get(item, "data")
          additional = Map.get(item, "additional")
          merged_additional = merge_additional(acc_additional, additional)
          {[extract_ticket_data(data_map) | acc_data], merged_additional}

        is_map(item) and Map.has_key?(item, "checksum") ->
          {[extract_ticket_data(item) | acc_data], acc_additional}

        is_map(item) and is_map(Map.get(item, "additional")) ->
          {acc_data, merge_additional(acc_additional, Map.get(item, "additional"))}

        true ->
          {acc_data, acc_additional}
      end
    end)
    |> then(fn {data, additional} -> {Enum.reverse(data), additional} end)
  end

  defp extract_tickets_page(_response), do: {[], %{}}

  defp extract_ticket_data(%{"data" => %{} = inner}), do: inner
  defp extract_ticket_data(%{data: %{} = inner}), do: inner
  defp extract_ticket_data(%{} = item), do: item
  defp extract_ticket_data(_item), do: %{}

  defp merge_additional(acc, %{} = additional), do: Map.merge(acc, additional)
  defp merge_additional(acc, _), do: acc

  defp extract_results_count(additional, data) do
    additional
    |> Map.get("results_count", Map.get(additional, :results_count))
    |> coerce_integer()
    |> case do
      count when count > 0 -> count
      _ -> length(data)
    end
  end

  defp normalize_custom_fields(fields) when is_list(fields) do
    fields
    |> Enum.map(&normalize_custom_field/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_custom_fields(%{} = fields) do
    fields
    |> Enum.map(fn {name, value} ->
      {normalize_custom_field_name(name), normalize_custom_field_value(value)}
    end)
  end

  defp normalize_custom_fields(_), do: []

  defp normalize_custom_field(%{} = field) do
    name =
      Map.get(field, "name") ||
        Map.get(field, "field") ||
        Map.get(field, :name) ||
        Map.get(field, :field)

    value = Map.get(field, "value") || Map.get(field, :value)
    {normalize_custom_field_name(name), normalize_custom_field_value(value)}
  end

  defp normalize_custom_field([name, value]) do
    {normalize_custom_field_name(name), normalize_custom_field_value(value)}
  end

  defp normalize_custom_field({name, value}) do
    {normalize_custom_field_name(name), normalize_custom_field_value(value)}
  end

  defp normalize_custom_field(_), do: nil

  defp normalize_custom_field_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_custom_field_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_custom_field_name(name) when is_number(name), do: to_string(name)
  defp normalize_custom_field_name(_), do: ""

  defp normalize_custom_field_value(nil), do: nil
  defp normalize_custom_field_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_custom_field_value(value), do: value

  defp pick_field(map, keys) when is_map(map) and is_list(keys) do
    keys
    |> Enum.find_value(fn key -> normalize_optional_string(Map.get(map, key)) end)
  end

  defp find_custom_field_value(custom_map, include_patterns, exclude_patterns \\ [])

  defp find_custom_field_value(custom_map, include_patterns, exclude_patterns)
       when is_map(custom_map) do
    custom_map
    |> Enum.find_value(fn {name, value} ->
      name_str = String.downcase(to_string(name))

      include? = Enum.any?(include_patterns, &Regex.match?(&1, name_str))
      excluded? = Enum.any?(exclude_patterns, &Regex.match?(&1, name_str))

      if include? and not excluded? do
        normalize_optional_string(value)
      else
        nil
      end
    end)
  end

  defp find_custom_field_value(_custom_map, _include_patterns, _exclude_patterns), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_number(value), do: to_string(value)
  defp normalize_optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp normalize_non_negative_int(nil), do: nil

  defp normalize_non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative_int(value) when is_integer(value), do: 0

  defp normalize_non_negative_int(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        case Integer.parse(trimmed) do
          {number, _} when number >= 0 -> number
          {number, _} when number < 0 -> 0
          _ -> nil
        end
    end
  end

  defp normalize_non_negative_int(value) when is_float(value), do: trunc(max(value, 0))
  defp normalize_non_negative_int(_value), do: nil

  defp normalize_checked_in_flag(nil), do: nil

  defp normalize_checked_in_flag(value) when is_boolean(value), do: value

  defp normalize_checked_in_flag(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "yes" -> true
      "true" -> true
      "1" -> true
      "no" -> false
      "false" -> false
      "0" -> false
      _ -> nil
    end
  end

  defp normalize_checked_in_flag(_value), do: nil

  defp handle_attendee_fallback(site_url, api_key, reason, partial \\ []) do
    case Fallback.maybe_use_cached(site_url, api_key, reason) do
      {:ok, cached} ->
        parsed = Enum.map(cached, &parse_attendee/1)
        {:fallback, parsed, length(parsed)}

      {:error, "NO_CACHED_DATA"} ->
        {:error, reason, partial}

      {:error, fallback_reason} ->
        {:error, {:fallback_error, fallback_reason}, partial}
    end
  end

  defp handle_advanced_network_error(%TransportError{reason: reason}),
    do: handle_advanced_network_error(reason)

  defp handle_advanced_network_error(%Mint.TransportError{reason: reason}),
    do: handle_advanced_network_error(reason)

  defp handle_advanced_network_error(%Finch.Error{reason: reason}),
    do: handle_advanced_network_error(reason)

  defp handle_advanced_network_error(reason) do
    case reason do
      :timeout ->
        Logger.error("TickeraClient: submit_advanced_check_in – NETWORK_TIMEOUT")
        {:error, "NETWORK_TIMEOUT", "Tickera advanced check-in request timed out"}

      :connect_timeout ->
        Logger.error("TickeraClient: submit_advanced_check_in – NETWORK_TIMEOUT")
        {:error, "NETWORK_TIMEOUT", "Tickera advanced check-in request timed out"}

      {:timeout, _} ->
        Logger.error("TickeraClient: submit_advanced_check_in – NETWORK_TIMEOUT")
        {:error, "NETWORK_TIMEOUT", "Tickera advanced check-in request timed out"}

      _ ->
        Logger.error("TickeraClient: submit_advanced_check_in – NETWORK_ERROR #{inspect(reason)}")
        {:error, "NETWORK_ERROR", "Tickera advanced check-in failed"}
    end
  end

  defp normalize_advanced_check_in(%{} = payload) do
    case extract_business_error(payload) do
      {:error, code, _message} = error ->
        if code in @advanced_business_errors do
          Logger.warning("TickeraClient: submit_advanced_check_in – #{code}")
        else
          Logger.warning("TickeraClient: submit_advanced_check_in – BUSINESS_ERROR")
        end

        error

      :ok ->
        payload
        |> Map.get("data")
        |> case do
          %{} = data -> data
          _ -> payload
        end
        |> normalize_advanced_payload()
    end
  end

  defp normalize_advanced_check_in(_payload) do
    Logger.error("Tickera advanced check-in payload missing")
    {:error, "JSON_ERROR", "Response not valid JSON"}
  end

  defp normalize_advanced_payload(%{} = data) do
    normalized =
      Enum.reduce(data, %{}, fn {key, value}, acc ->
        maybe_put_advanced_field(acc, key, value)
      end)

    {:ok, normalized}
  end

  defp normalize_advanced_payload(_data) do
    {:ok, %{}}
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

  defp decode_check_in_history(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) ->
        {:ok, Enum.map(list, &normalize_check_in_record/1)}

      {:ok, %{} = payload} ->
        case extract_business_error(payload) do
          {:error, code, message} ->
            Logger.warning("TickeraClient: fetch_check_in_history – #{code}")
            {:error, code, message}

          :ok ->
            history =
              cond do
                is_list(Map.get(payload, "history")) -> Map.get(payload, "history")
                is_list(Map.get(payload, "data")) -> Map.get(payload, "data")
                true -> []
              end

            {:ok, Enum.map(history, &normalize_check_in_record/1)}
        end

      {:ok, _other} ->
        Logger.error("Tickera check-in history response was not a JSON array")
        {:error, "JSON_ERROR", "Response not valid JSON"}

      {:error, _error} ->
        Logger.error("Tickera check-in history response was not valid JSON")
        {:error, "JSON_ERROR", "Response not valid JSON"}
    end
  end

  defp normalize_ticket_config(%{} = payload) do
    case extract_business_error(payload) do
      {:error, code, message} ->
        Logger.warning("TickeraClient: get_ticket_config – #{code}")
        {:error, code, message}

      :ok ->
        data_map =
          payload
          |> Map.get("data")
          |> case do
            %{} = inner -> inner
            _ -> payload
          end

        if is_map(data_map) do
          normalized =
            Enum.reduce(data_map, %{}, fn {key, value}, acc ->
              maybe_put_ticket_config_field(acc, key, value)
            end)
            |> Map.put_new(:allowed_checkins, 1)

          {:ok, normalized}
        else
          Logger.error("Tickera ticket config payload missing data")
          {:error, "JSON_ERROR", "Response not valid JSON"}
        end
    end
  end

  defp normalize_ticket_config(_payload) do
    Logger.error("Tickera ticket config payload missing")
    {:error, "JSON_ERROR", "Response not valid JSON"}
  end

  defp normalize_ticket_payload(%{} = payload) do
    case extract_business_error(payload) do
      {:error, code, message} ->
        Logger.warning("TickeraClient: get_ticket_detailed_status – #{code}")
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

  defp maybe_put_advanced_field(acc, key, value) when is_binary(key) do
    case Map.get(@advanced_key_mapping, key) do
      nil -> acc
      field -> Map.put(acc, field, normalize_advanced_value(field, value))
    end
  end

  defp maybe_put_advanced_field(acc, key, value) when is_atom(key) do
    maybe_put_advanced_field(acc, Atom.to_string(key), value)
  end

  defp maybe_put_advanced_field(acc, _key, _value), do: acc

  defp normalize_advanced_value(key, value) when key in @advanced_integer_fields,
    do: coerce_integer(value)

  defp normalize_advanced_value(key, value) when key in @advanced_boolean_fields,
    do: coerce_boolean(value)

  defp normalize_advanced_value(key, value) when key in @advanced_string_fields,
    do: coerce_string(value)

  defp normalize_advanced_value(_key, value), do: value

  defp normalize_event_occupancy(%{} = payload) do
    case extract_business_error(payload) do
      {:error, code, message} ->
        Logger.warning("TickeraClient: get_event_occupancy – #{code}")
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

  defp maybe_put_ticket_config_field(acc, key, value) when is_binary(key) do
    case Map.get(@ticket_config_key_mapping, key) do
      nil -> acc
      atom_key -> Map.put(acc, atom_key, normalize_ticket_config_value(atom_key, value))
    end
  end

  defp maybe_put_ticket_config_field(acc, key, value) when is_atom(key) do
    maybe_put_ticket_config_field(acc, Atom.to_string(key), value)
  end

  defp maybe_put_ticket_config_field(acc, _key, _value), do: acc

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

  defp normalize_ticket_config_value(key, value) when key in @ticket_config_integer_fields,
    do: coerce_integer(value)

  defp normalize_ticket_config_value(key, value) when key in @ticket_config_float_fields,
    do: coerce_float(value)

  defp normalize_ticket_config_value(key, value) when key in @ticket_config_boolean_fields,
    do: coerce_boolean(value)

  defp normalize_ticket_config_value(key, value) when key in @ticket_config_date_fields,
    do: coerce_date(value)

  defp normalize_ticket_config_value(_key, value), do: value

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

  defp coerce_string(nil), do: nil

  defp coerce_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> ""
      trimmed -> trimmed
    end
  end

  defp coerce_string(value), do: to_string(value)

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

  defp coerce_time(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        case Time.from_iso8601(trimmed) do
          {:ok, time} -> time
          {:error, _} -> nil
        end
    end
  end

  defp coerce_time(%Time{} = time), do: time
  defp coerce_time(_value), do: nil

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

  defp request(method, url, opts) do
    opts = normalize_req_timeouts(opts)

    req_opts =
      opts
      |> Keyword.put(:method, method)
      |> Keyword.put(:url, url)
      |> Keyword.update(:headers, [], &List.wrap/1)
      |> Keyword.put(:into, nil)
      |> Keyword.put_new(:decode_body, false)

    req = Req.new(req_opts)

    request_fun().(req)
  end

  defp normalize_req_timeouts(opts) when is_list(opts) do
    case Keyword.pop(opts, :connect_timeout) do
      {nil, remaining_opts} ->
        remaining_opts

      {timeout, remaining_opts} when is_integer(timeout) and timeout > 0 ->
        connect_options =
          remaining_opts
          |> Keyword.get(:connect_options, [])
          |> Keyword.put_new(:timeout, timeout)

        Keyword.put(remaining_opts, :connect_options, connect_options)

      {_timeout, remaining_opts} ->
        remaining_opts
    end
  end

  defp request_fun do
    Application.get_env(:fastcheck, :tickera_request_fun, @request_fun)
  end

  defp build_url(site_url, api_key, endpoint) do
    trimmed = site_url |> to_string() |> String.trim()

    normalized_site_url =
      case Regex.match?(~r/^https?:\/\//i, trimmed) do
        true -> trimmed
        false -> "https://#{trimmed}"
      end
      |> String.trim_trailing("/")

    endpoint = endpoint |> to_string() |> String.trim_leading("/")
    "#{normalized_site_url}/tc-api/#{api_key}/#{endpoint}"
  end

  defp safe_log_url(url) when is_binary(url) do
    Regex.replace(~r{/tc-api/[^/?#]+}, url, "/tc-api/[REDACTED]")
  end

  defp safe_log_url(url), do: url

  defp fetch_json(url) do
    Logger.debug("TickeraClient GET #{safe_log_url(url)}")

    try do
      headers =
        [{"accept", "application/json"}]
        |> default_tickera_headers()

      case request(:get, url,
             headers: headers,
             connect_timeout: @timeout,
             receive_timeout: @timeout
           ) do
        {:ok, %Response{status: code, body: raw_body, headers: response_headers}}
        when code in 200..299 ->
          handle_fetch_json_success(url, code, raw_body, response_headers, headers)

        {:ok, %Response{status: code, body: body}} ->
          normalized = normalize_response_body(body)
          reason = classify_http_status(code, normalized)
          Logger.error("Tickera request failed (status #{code}): #{body_preview(normalized)}")
          {:error, reason}

        {:error, error} ->
          classified = classify_network_error(error)
          Logger.error("Tickera request error: #{inspect(error)}")
          {:error, classified}
      end
    rescue
      exception ->
        Logger.error("Tickera request exception: #{Exception.message(exception)}")
        {:error, {:exception, Exception.message(exception)}}
    end
  end

  defp handle_fetch_json_success(url, status, raw_body, response_headers, request_headers) do
    body = normalize_response_body(raw_body)

    if body == "" do
      log_empty_body_response(url, status, raw_body, response_headers, :initial)
      retry_empty_body_request(url, request_headers)
    else
      decode_json_body(body, url)
    end
  end

  defp retry_empty_body_request(url, headers) do
    retry_url = add_cache_buster(url)

    Logger.warning(
      "Retrying Tickera request after empty body for #{safe_log_url(url)} as #{safe_log_url(retry_url)}"
    )

    case request(:get, retry_url,
           headers: headers,
           connect_timeout: @timeout,
           receive_timeout: @timeout
         ) do
      {:ok, %Response{status: code, body: raw_body, headers: response_headers}}
      when code in 200..299 ->
        body = normalize_response_body(raw_body)

        if body == "" do
          log_empty_body_response(retry_url, code, raw_body, response_headers, :retry)

          headers
          |> build_empty_body_fallback_headers(url)
          |> retry_empty_body_request_with_fallback_profile(url)
        else
          decode_json_body(body, retry_url)
        end

      {:ok, %Response{status: code, body: body}} ->
        normalized = normalize_response_body(body)
        reason = classify_http_status(code, normalized)
        Logger.error("Tickera retry request failed (status #{code}): #{body_preview(normalized)}")
        {:error, reason}

      {:error, error} ->
        classified = classify_network_error(error)
        Logger.error("Tickera retry request error: #{inspect(error)}")
        {:error, classified}
    end
  end

  defp retry_empty_body_request_with_fallback_profile(headers, url) do
    retry_url =
      url
      |> ensure_endpoint_trailing_slash()
      |> add_cache_buster()

    Logger.warning(
      "Retrying Tickera request with fallback profile after empty body for #{safe_log_url(url)} as #{safe_log_url(retry_url)}"
    )

    case request(:get, retry_url,
           headers: headers,
           connect_timeout: @timeout,
           receive_timeout: @timeout
         ) do
      {:ok, %Response{status: code, body: raw_body, headers: response_headers}}
      when code in 200..299 ->
        body = normalize_response_body(raw_body)

        if body == "" do
          log_empty_body_response(retry_url, code, raw_body, response_headers, :fallback)
          {:error, {:http_error, :empty_body, empty_body_hint(response_headers, retry_url)}}
        else
          decode_json_body(body, retry_url)
        end

      {:ok, %Response{status: code, body: body}} ->
        normalized = normalize_response_body(body)
        reason = classify_http_status(code, normalized)

        Logger.error(
          "Tickera fallback-profile request failed (status #{code}): #{body_preview(normalized)}"
        )

        {:error, reason}

      {:error, error} ->
        classified = classify_network_error(error)
        Logger.error("Tickera fallback-profile request error: #{inspect(error)}")
        {:error, classified}
    end
  end

  defp decode_json_body(body, url) do
    case Jason.decode(body) do
      {:ok, data} ->
        {:ok, data}

      {:error, error} ->
        Logger.error(
          "Failed to decode Tickera response from #{safe_log_url(url)}: #{inspect(error)} body=#{inspect(body_preview(body))}"
        )

        {:error, {:http_error, :invalid_json, error}}
    end
  end

  defp log_empty_body_response(url, status, raw_body, response_headers, attempt) do
    Logger.error(
      "Tickera returned an empty response body (attempt=#{attempt} status=#{status} content_length=#{header_value(response_headers, "content-length") || "unknown"} content_type=#{header_value(response_headers, "content-type") || "unknown"} server=#{header_value(response_headers, "server") || "unknown"} cf_ray=#{header_value(response_headers, "cf-ray") || "n/a"})",
      url: safe_log_url(url),
      attempt: attempt,
      status: status,
      raw_type: response_body_type(raw_body),
      raw_size: response_body_size(raw_body),
      content_type: header_value(response_headers, "content-type"),
      content_length: header_value(response_headers, "content-length"),
      server: header_value(response_headers, "server"),
      cf_ray: header_value(response_headers, "cf-ray")
    )
  end

  defp default_tickera_headers(headers) do
    headers
    |> put_or_replace_header("user-agent", @tickera_user_agent)
    |> put_or_replace_header("accept-language", "en-US,en;q=0.9")
    |> put_or_replace_header("accept-encoding", "identity")
    |> put_or_replace_header("cache-control", "no-cache")
    |> put_or_replace_header("pragma", "no-cache")
  end

  defp build_empty_body_fallback_headers(headers, url) do
    headers
    |> maybe_put_tickera_authorization(url)
    |> put_or_replace_header("accept", "application/json, text/plain, */*")
    |> put_or_replace_header("accept-encoding", "identity")
  end

  defp maybe_put_tickera_authorization(headers, url) do
    case extract_api_key_from_url(url) do
      nil -> headers
      api_key -> put_or_replace_header(headers, "authorization", "Bearer #{api_key}")
    end
  end

  defp extract_api_key_from_url(url) when is_binary(url) do
    case Regex.run(~r{/tc-api/([^/?#]+)/}, url, capture: :all_but_first) do
      [api_key] when api_key != "" -> api_key
      _ -> nil
    end
  end

  defp extract_api_key_from_url(_url), do: nil

  defp put_or_replace_header(headers, key, value) when is_list(headers) do
    downcased_key = String.downcase(key)

    filtered =
      Enum.reject(headers, fn
        {name, _value} -> String.downcase(to_string(name)) == downcased_key
        _other -> false
      end)

    filtered ++ [{key, value}]
  end

  defp put_or_replace_header(_headers, key, value), do: [{key, value}]

  defp header_value(headers, key) when is_list(headers) do
    downcased_key = String.downcase(key)

    Enum.find_value(headers, fn
      {name, value} when is_binary(name) ->
        if String.downcase(name) == downcased_key, do: value

      {name, value} ->
        if String.downcase(to_string(name)) == downcased_key, do: value

      _other ->
        nil
    end)
  end

  defp header_value(headers, key) when is_map(headers) do
    downcased_key = String.downcase(key)

    headers
    |> Enum.find_value(fn
      {name, value} when is_binary(name) ->
        if String.downcase(name) == downcased_key do
          normalize_header_value(value)
        end

      {name, value} ->
        if String.downcase(to_string(name)) == downcased_key do
          normalize_header_value(value)
        end
    end)
  end

  defp header_value(_headers, _key), do: nil

  defp normalize_header_value([first | _]) when is_binary(first), do: first
  defp normalize_header_value(value) when is_binary(value), do: value
  defp normalize_header_value(value), do: to_string(value)

  defp ensure_endpoint_trailing_slash(url) when is_binary(url) do
    uri = URI.parse(url)
    path = uri.path || ""

    cond do
      path == "" ->
        url

      String.ends_with?(path, "/") ->
        url

      true ->
        URI.to_string(%{uri | path: "#{path}/"})
    end
  rescue
    _error -> url
  end

  defp ensure_endpoint_trailing_slash(url), do: url

  defp empty_body_hint(response_headers, url) do
    content_length = header_value(response_headers, "content-length") || "unknown"
    content_type = header_value(response_headers, "content-type") || "unknown"
    server = header_value(response_headers, "server") || "unknown"

    cf_ray_hint =
      case header_value(response_headers, "cf-ray") do
        nil -> ""
        value -> " cf_ray=#{value}"
      end

    credential_hint = maybe_probe_credentials_after_empty_body(url)

    "Tickera returned HTTP success with an empty body (content_length=#{content_length}, content_type=#{content_type}, server=#{server}).#{cf_ray_hint}#{credential_hint}"
  end

  defp maybe_probe_credentials_after_empty_body(url) when is_binary(url) do
    with api_key when is_binary(api_key) <- extract_api_key_from_url(url),
         site_url when is_binary(site_url) <- extract_site_url_from_tickera_url(url) do
      check_url = build_url(site_url, api_key, "check_credentials")
      headers = default_tickera_headers([{"accept", "application/json"}])

      case request(:get, check_url,
             headers: headers,
             connect_timeout: min(@timeout, 10_000),
             receive_timeout: min(@timeout, 10_000)
           ) do
        {:ok, %Response{status: code, body: body}} when code in 200..299 ->
          case decode_credential_pass_value(body) do
            :pass -> " credential_check=pass"
            :fail -> " credential_check=fail"
            :unknown -> " credential_check=unknown"
            :invalid_json -> " credential_check=invalid_json"
          end

        {:ok, %Response{status: code}} ->
          " credential_check=http_#{code}"

        {:error, _error} ->
          " credential_check=unreachable"
      end
    else
      _ -> ""
    end
  rescue
    _error -> " credential_check=probe_error"
  end

  defp maybe_probe_credentials_after_empty_body(_url), do: ""

  defp decode_credential_pass_value(raw_body) do
    body = normalize_response_body(raw_body)

    case Jason.decode(body) do
      {:ok, %{} = payload} ->
        pass = Map.get(payload, "pass", Map.get(payload, :pass))

        cond do
          pass in [true, "true", "1", 1] -> :pass
          pass in [false, "false", "0", 0, "", nil] -> :fail
          true -> :unknown
        end

      _ ->
        :invalid_json
    end
  end

  defp extract_site_url_from_tickera_url(url) when is_binary(url) do
    uri = URI.parse(url)
    path = uri.path || ""

    case String.split(path, "/tc-api/", parts: 2) do
      [base_path, _rest] ->
        URI.to_string(%{uri | path: base_path, query: nil, fragment: nil})

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  defp extract_site_url_from_tickera_url(_url), do: nil

  defp add_cache_buster(url) when is_binary(url) do
    uri = URI.parse(url)
    existing_query = if uri.query in [nil, ""], do: %{}, else: URI.decode_query(uri.query)
    query = Map.put(existing_query, "_fc", Integer.to_string(System.system_time(:millisecond)))
    URI.to_string(%{uri | query: URI.encode_query(query)})
  rescue
    _error -> url
  end

  defp add_cache_buster(url), do: url

  defp classify_http_status(code, body) when is_integer(code) and code >= 500,
    do: {:server_error, code, body}

  defp classify_http_status(code, body), do: {:http_error, code, body}

  defp classify_network_error(%TransportError{reason: reason}),
    do: classify_network_reason(reason)

  defp classify_network_error(%Mint.TransportError{reason: reason}),
    do: classify_network_reason(reason)

  defp classify_network_error(%Finch.Error{reason: reason}), do: classify_network_reason(reason)

  defp classify_network_error(reason) when is_atom(reason) or is_tuple(reason),
    do: classify_network_reason(reason)

  defp classify_network_error(reason), do: {:network_error, reason}

  defp classify_network_reason(reason) when reason in [:timeout, :connect_timeout],
    do: {:network_timeout, reason}

  defp classify_network_reason({:timeout, _} = reason), do: {:network_timeout, reason}
  defp classify_network_reason(reason), do: {:network_error, reason}

  defp normalize_response_body(body) when is_binary(body), do: String.trim(body)

  defp normalize_response_body(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> String.trim(encoded)
      {:error, _reason} -> ""
    end
  end

  defp normalize_response_body(body) when is_list(body) do
    body
    |> IO.iodata_to_binary()
    |> String.trim()
  rescue
    ArgumentError ->
      case Jason.encode(body) do
        {:ok, encoded} -> String.trim(encoded)
        {:error, _reason} -> ""
      end
  end

  defp normalize_response_body(nil), do: ""
  defp normalize_response_body(_other), do: ""

  defp response_body_type(body) when is_binary(body), do: :binary
  defp response_body_type(body) when is_map(body), do: :map
  defp response_body_type(body) when is_list(body), do: :list
  defp response_body_type(nil), do: nil
  defp response_body_type(_body), do: :other

  defp response_body_size(body) when is_binary(body), do: byte_size(body)
  defp response_body_size(body) when is_map(body), do: map_size(body)

  defp response_body_size(body) when is_list(body) do
    body
    |> IO.iodata_to_binary()
    |> byte_size()
  rescue
    ArgumentError -> length(body)
  end

  defp response_body_size(nil), do: 0
  defp response_body_size(_body), do: nil

  defp body_preview(body) when is_binary(body) do
    body
    |> String.slice(0, 300)
    |> String.replace(~r/\s+/, " ")
  end

  defp body_preview(_body), do: ""

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

  defp normalize_check_in_record(%{} = record) do
    %{
      date: record |> Map.get("date") |> coerce_date(),
      time: record |> Map.get("time") |> coerce_time(),
      entrance: Map.get(record, "entrance") || Map.get(record, "entrance_name"),
      check_in_type: Map.get(record, "check_in_type") || Map.get(record, "checkin_type"),
      status: Map.get(record, "status"),
      operator: Map.get(record, "operator") || Map.get(record, "operator_name")
    }
  end

  defp normalize_check_in_record(_record) do
    %{
      date: nil,
      time: nil,
      entrance: nil,
      check_in_type: nil,
      status: nil,
      operator: nil
    }
  end
end
