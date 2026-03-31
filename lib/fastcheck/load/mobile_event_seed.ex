defmodule FastCheck.Load.MobileEventSeed do
  @moduledoc """
  Generates deterministic mobile scan performance fixtures and a manifest for k6.
  """

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  @min_attendees 20
  @minimum_slice_total 20
  @baseline_min 8
  @business_duplicate_min 2
  @offline_burst_min 5
  @default_output_dir Path.join(["performance", "manifests"])
  @insert_chunk_size 1_000
  @default_event_name_prefix "Mobile Load Test Event"
  @seed_site_url "https://loadtest.example.com"

  @type seed_result :: %{
          event: Event.t(),
          manifest: map(),
          manifest_path: String.t()
        }

  @spec seed(map() | keyword()) :: {:ok, seed_result()} | {:error, String.t()}
  def seed(opts) when is_list(opts) or is_map(opts) do
    with {:ok, normalized} <- normalize_options(opts),
         {:ok, %{event: event, manifest: manifest}} <- insert_seed_data(normalized),
         {:ok, manifest_path} <- write_manifest(manifest, normalized.output_path) do
      {:ok, %{event: event, manifest: manifest, manifest_path: manifest_path}}
    end
  end

  @spec seed!(map() | keyword()) :: seed_result()
  def seed!(opts) do
    case seed(opts) do
      {:ok, result} ->
        result

      {:error, reason} ->
        raise ArgumentError, "unable to seed mobile load event: #{reason}"
    end
  end

  @spec default_event_name_prefix() :: String.t()
  def default_event_name_prefix, do: @default_event_name_prefix

  @spec seed_site_url() :: String.t()
  def seed_site_url, do: @seed_site_url

  defp normalize_options(opts) do
    opts = if is_map(opts), do: Enum.into(opts, []), else: opts

    with {:ok, attendees} <- require_positive_integer(opts[:attendees], "--attendees is required"),
         :ok <- validate_attendee_count(attendees),
         {:ok, credential} <-
           require_non_empty_string(opts[:credential], "--credential is required") do
      ticket_prefix =
        opts[:ticket_prefix]
        |> sanitize_ticket_prefix()
        |> default_ticket_prefix()

      event_name =
        opts[:event_name]
        |> normalize_optional_string()
        |> case do
          nil -> "#{@default_event_name_prefix} #{System.unique_integer([:positive])}"
          value -> value
        end

      {:ok,
       %{
         attendees: attendees,
         credential: credential,
         event_name: event_name,
         output_path: normalize_optional_string(opts[:output]),
         scanner_code:
           opts[:scanner_code]
           |> normalize_optional_string()
           |> maybe_uppercase()
           |> default_scanner_code(),
         ticket_prefix: ticket_prefix
       }}
    end
  end

  defp insert_seed_data(opts) do
    Repo.transaction(fn ->
      event = create_event!(opts)
      ticket_width = max(String.length(Integer.to_string(opts.attendees)), 6)
      slices = build_slices(opts.attendees, opts.ticket_prefix, ticket_width)
      controls = build_control_ranges(slices, event.id)

      insert_attendees!(event.id, opts.ticket_prefix, opts.attendees, ticket_width)

      manifest = build_manifest(event, opts, slices, controls, ticket_width)

      %{event: event, manifest: manifest}
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp create_event!(opts) do
    api_key = "load-test-api-key-#{System.unique_integer([:positive])}"
    {:ok, encrypted_api_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_secret} = Crypto.encrypt(opts.credential)

    event_attrs = %{
      checked_in_count: 0,
      entrance_name: "Main Gate",
      mobile_access_secret_encrypted: encrypted_secret,
      name: opts.event_name,
      scanner_login_code: opts.scanner_code,
      site_url: @seed_site_url,
      status: "active",
      tickera_api_key_encrypted: encrypted_api_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      tickera_site_url: @seed_site_url,
      total_tickets: opts.attendees
    }

    %Event{}
    |> Event.changeset(event_attrs)
    |> Repo.insert!()
  end

  defp insert_attendees!(event_id, ticket_prefix, attendees, ticket_width) do
    timestamp = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    1..attendees
    |> Stream.map(fn index ->
      %{
        allowed_checkins: 1,
        checkins_remaining: 1,
        email: "load-#{index}@example.com",
        event_id: event_id,
        first_name: "Load#{index}",
        inserted_at: timestamp,
        is_currently_inside: false,
        last_name: "Tester",
        payment_status: "completed",
        ticket_code: ticket_code(ticket_prefix, index, ticket_width),
        ticket_type: "General Admission",
        updated_at: timestamp
      }
    end)
    |> Stream.chunk_every(@insert_chunk_size)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Attendee, chunk)
    end)
  end

  defp build_manifest(event, opts, slices, controls, ticket_width) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      event_id: event.id,
      event_name: event.name,
      scanner_login_code: event.scanner_login_code,
      credential: opts.credential,
      ticket_prefix: opts.ticket_prefix,
      ticket_count: opts.attendees,
      ticket_width: ticket_width,
      invalid_prefix: "INVALID-#{opts.ticket_prefix}",
      target_mode: "redis_authoritative",
      slices: slices,
      control_ranges: controls,
      idempotency_replay: %{
        reserve_count: controls.replay_prime_count,
        seed: "replay-#{event.id}",
        slice: "baseline_valid",
        strategy: "Use <seed>-<ticket_code> for primed replay duplicates."
      }
    }
  end

  defp build_control_ranges(slices, event_id) do
    %{
      business_prime_count:
        min(max(5, div(slices.business_duplicate.count, 2)), slices.business_duplicate.count),
      recovery_ticket: %{
        idempotency_key: "recovery-#{event_id}",
        index: slices.soak.start_index,
        ticket_code: slices.soak.start_ticket
      },
      replay_prime_count:
        min(max(5, div(slices.baseline_valid.count, 4)), slices.baseline_valid.count)
    }
  end

  defp build_slices(attendees, ticket_prefix, ticket_width) do
    extra_attendees = attendees - @minimum_slice_total

    counts = %{
      baseline_valid: @baseline_min + div(extra_attendees * 40, 100),
      business_duplicate: @business_duplicate_min + div(extra_attendees * 10, 100),
      offline_burst: @offline_burst_min + div(extra_attendees * 20, 100)
    }

    soak_count = attendees - Enum.sum(Map.values(counts))
    counts = Map.put(counts, :soak, soak_count)

    [:baseline_valid, :business_duplicate, :offline_burst, :soak]
    |> Enum.reduce({1, %{}}, fn slice_name, {start_index, acc} ->
      count = Map.fetch!(counts, slice_name)
      end_index = start_index + count - 1

      slice = %{
        count: count,
        end_index: end_index,
        end_ticket: ticket_code(ticket_prefix, end_index, ticket_width),
        start_index: start_index,
        start_ticket: ticket_code(ticket_prefix, start_index, ticket_width)
      }

      {end_index + 1, Map.put(acc, slice_name, slice)}
    end)
    |> elem(1)
  end

  defp write_manifest(manifest, nil) do
    default_path =
      Path.join(@default_output_dir, "mobile-load-event-#{manifest.event_id}.json")
      |> Path.expand()

    write_manifest(manifest, default_path)
  end

  # Internal CLI helper: the operator intentionally chooses the manifest output path.
  # sobelow_skip ["Traversal"]
  defp write_manifest(manifest, output_path) do
    output_path = Path.expand(output_path)
    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, Jason.encode_to_iodata!(manifest, pretty: true))
    {:ok, output_path}
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp ticket_code(ticket_prefix, index, ticket_width) do
    "#{ticket_prefix}-#{String.pad_leading(Integer.to_string(index), ticket_width, "0")}"
  end

  defp sanitize_ticket_prefix(nil), do: nil

  defp sanitize_ticket_prefix(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> nil
      sanitized -> sanitized
    end
  end

  defp sanitize_ticket_prefix(_value), do: nil

  defp default_ticket_prefix(nil), do: "LOAD#{System.unique_integer([:positive])}"
  defp default_ticket_prefix(value), do: value

  defp require_positive_integer(value, _message) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp require_positive_integer(value, message) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, message}
    end
  end

  defp require_positive_integer(_value, message), do: {:error, message}

  defp require_non_empty_string(value, _message) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "--credential is required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp require_non_empty_string(_value, message), do: {:error, message}

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp maybe_uppercase(nil), do: nil
  defp maybe_uppercase(value), do: String.upcase(value)

  defp default_scanner_code(nil) do
    Ecto.UUID.generate()
    |> String.replace("-", "")
    |> String.upcase()
    |> String.slice(0, 6)
  end

  defp default_scanner_code(value), do: value

  defp validate_attendee_count(attendees) when attendees < @min_attendees do
    {:error, "--attendees must be at least #{@min_attendees} to produce non-overlapping slices"}
  end

  defp validate_attendee_count(_attendees), do: :ok
end
