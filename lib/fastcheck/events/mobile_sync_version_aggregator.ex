defmodule FastCheck.Events.MobileSyncVersionAggregator do
  @moduledoc """
  Sales-origin boundary for attendee changes that must become visible to
  mobile scanner sync.

  The durable event sync version bump is correctness-critical. Cache
  invalidation is best-effort and must not leak ticket codes or customer data.
  """

  require Logger

  alias FastCheck.Attendees
  alias FastCheck.Events

  @type error_reason :: :invalid_event_id | :no_ticket_codes | :event_not_found

  @doc """
  Marks newly-created attendees as visible to mobile sync for an event.

  Returns `:ok` after a durable event sync version bump. Cache invalidation
  failures are logged safely and do not change the return value.
  """
  @spec after_attendees_created(integer(), [String.t()], keyword()) ::
          :ok | {:error, error_reason()}
  def after_attendees_created(event_id, ticket_codes, opts \\ [])

  def after_attendees_created(event_id, ticket_codes, opts)
      when is_integer(event_id) and event_id > 0 do
    normalized_ticket_codes = normalize_ticket_codes(ticket_codes)

    if normalized_ticket_codes == [] do
      {:error, :no_ticket_codes}
    else
      case Events.bump_event_sync_version(event_id) do
        :ok ->
          unless Keyword.get(opts, :skip_cache_invalidation, false) do
            invalidate_caches(event_id, normalized_ticket_codes, opts)
          end

          :ok

        {:error, :event_not_found} = error ->
          error
      end
    end
  end

  def after_attendees_created(_event_id, _ticket_codes, _opts), do: {:error, :invalid_event_id}

  @doc false
  @spec invalidate_attendees_created_caches(integer(), [String.t()], keyword()) ::
          :ok | {:error, error_reason()}
  def invalidate_attendees_created_caches(event_id, ticket_codes, opts \\ [])

  def invalidate_attendees_created_caches(event_id, ticket_codes, opts)
      when is_integer(event_id) and event_id > 0 do
    normalized_ticket_codes = normalize_ticket_codes(ticket_codes)

    if normalized_ticket_codes == [] do
      {:error, :no_ticket_codes}
    else
      invalidate_caches(event_id, normalized_ticket_codes, opts)
      :ok
    end
  end

  def invalidate_attendees_created_caches(_event_id, _ticket_codes, _opts),
    do: {:error, :invalid_event_id}

  @doc """
  Marks attendee invalidation as visible to mobile sync for an event.

  Mirrors `after_attendees_created/3`: durable bump is correctness-critical;
  cache invalidation is best-effort unless skipped via `:skip_cache_invalidation`.
  """
  @spec after_attendee_invalidated(integer(), integer(), String.t(), String.t(), keyword()) ::
          :ok | {:error, error_reason()}
  def after_attendee_invalidated(event_id, attendee_id, ticket_code, _reason_code, opts \\ [])

  def after_attendee_invalidated(event_id, attendee_id, ticket_code, _reason_code, opts)
      when is_integer(event_id) and event_id > 0 and is_integer(attendee_id) and attendee_id > 0 and
             is_binary(ticket_code) do
    attendee_ids =
      opts
      |> Keyword.get(:attendee_ids, [attendee_id])
      |> normalize_attendee_ids()

    attendee_ids =
      if attendee_id in attendee_ids, do: attendee_ids, else: [attendee_id | attendee_ids]

    after_attendees_created(
      event_id,
      [ticket_code],
      Keyword.merge(opts,
        attendee_ids: attendee_ids,
        source: Keyword.get(opts, :source, :sales_revocation)
      )
    )
  end

  def after_attendee_invalidated(_event_id, _attendee_id, _ticket_code, _reason_code, _opts),
    do: {:error, :invalid_event_id}

  defp normalize_ticket_codes(ticket_codes) when is_list(ticket_codes) do
    ticket_codes
    |> Enum.map(&normalize_ticket_code/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_ticket_codes(ticket_code) when is_binary(ticket_code) do
    ticket_code
    |> normalize_ticket_code()
    |> List.wrap()
  end

  defp normalize_ticket_codes(_ticket_codes), do: []

  defp normalize_ticket_code(ticket_code) when is_binary(ticket_code) do
    ticket_code
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_ticket_code(_ticket_code), do: nil

  defp invalidate_caches(event_id, ticket_codes, opts) do
    cache_facade = Keyword.get(opts, :cache_facade, Attendees)
    attendee_ids = opts |> Keyword.get(:attendee_ids, []) |> normalize_attendee_ids()
    source = Keyword.get(opts, :source, :sales_issuer)
    counts = %{ticket_count: length(ticket_codes), attendee_count: length(attendee_ids)}

    Enum.each(ticket_codes, &FastCheck.Cache.EtsLayer.delete_attendee(event_id, &1))

    with_cache_failure_logging(event_id, source, counts, fn ->
      case cache_facade.invalidate_attendees_by_event_cache(event_id) do
        :ok -> :ok
        :error -> {:error, :attendee_event_cache}
      end
    end)

    Enum.each(attendee_ids, fn attendee_id ->
      with_cache_failure_logging(event_id, source, counts, fn ->
        case cache_facade.delete_attendee_id_cache(attendee_id) do
          :ok -> :ok
          :error -> {:error, :attendee_id_cache}
        end
      end)
    end)
  end

  defp normalize_attendee_ids(attendee_ids) when is_list(attendee_ids) do
    attendee_ids
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
  end

  defp normalize_attendee_ids(_attendee_ids), do: []

  defp with_cache_failure_logging(event_id, source, counts, fun) do
    case fun.() do
      :ok -> :ok
      {:error, reason} -> log_cache_failure(event_id, source, counts, reason)
    end
  rescue
    exception ->
      log_cache_failure(event_id, source, counts, Exception.message(exception))
  end

  defp log_cache_failure(event_id, source, counts, reason) do
    Logger.warning(
      "Mobile sync cache invalidation failed " <>
        "event_id=#{event_id} " <>
        "ticket_count=#{counts.ticket_count} " <>
        "attendee_count=#{counts.attendee_count} " <>
        "source=#{source} " <>
        "reason=#{inspect(reason)}"
    )
  end
end
