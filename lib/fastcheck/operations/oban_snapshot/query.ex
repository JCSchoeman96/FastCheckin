defmodule FastCheck.Operations.ObanSnapshot.Query do
  @moduledoc """
  Bounded SQL aggregates for the cold Oban jobs table.
  """

  alias FastCheck.Operations.ObanSnapshot
  alias FastCheck.Operations.ObanSnapshot.Clock
  alias FastCheck.Repo

  @discarded_recent_window_seconds 3_600
  @configured_queues ObanSnapshot.configured_queues()

  @spec active_rows(module(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def active_rows(repo \\ Repo, _collected_at \\ Clock.utc_now()) do
    sql = """
    SELECT
      CASE WHEN queue = ANY($1::text[]) THEN queue ELSE '__unexpected__' END AS normalized_queue,
      state,
      count(*) AS count,
      min(scheduled_at) AS min_scheduled_at,
      min(attempted_at) AS min_attempted_at
    FROM oban_jobs
    WHERE state IN (
      'available',
      'executing',
      'retryable',
      'scheduled'
    )
    GROUP BY normalized_queue, state
    """

    case repo_query(repo, sql, [ObanSnapshot.configured_queues()]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &active_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec discarded_rows(module(), DateTime.t()) :: {:ok, [map()]} | {:error, term()}
  def discarded_rows(repo \\ Repo, collected_at \\ Clock.utc_now()) do
    sql = """
    SELECT
      CASE WHEN queue = ANY($1::text[]) THEN queue ELSE '__unexpected__' END AS normalized_queue,
      count(*) AS count
    FROM oban_jobs
    WHERE state::text = 'discarded'
      AND discarded_at >= $2
    GROUP BY normalized_queue
    """

    window_start = DateTime.add(collected_at, -@discarded_recent_window_seconds, :second)

    case repo_query(repo, sql, [ObanSnapshot.configured_queues(), window_start]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &discarded_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec build_snapshot([map()], [map()], DateTime.t(), keyword()) :: map()
  def build_snapshot(active_rows, discarded_rows, collected_at, opts \\ []) do
    active = Enum.map(active_rows, &normalize_active/1)
    discarded = Enum.map(discarded_rows, &normalize_discarded/1)
    active_by_queue = Enum.group_by(active, & &1.queue)
    discarded_by_queue = Map.new(discarded, &{&1.queue, &1.count})

    queues =
      Enum.map(ObanSnapshot.queue_labels(), fn queue ->
        rows = Map.get(active_by_queue, queue, [])
        base = ObanSnapshot.empty_row(queue)

        row =
          Enum.reduce(rows, base, fn item, row ->
            state = item.state
            Map.update!(row, String.to_existing_atom(state), &(&1 + item.count))
          end)

        row
        |> Map.put(:discarded_recent_count, Map.get(discarded_by_queue, queue, 0))
        |> put_timing(rows, collected_at)
      end)

    %{
      version: ObanSnapshot.version(),
      collected_at: collected_at,
      collector_node: Keyword.get(opts, :collector_node, Atom.to_string(node())),
      distribution_mode: Keyword.get(opts, :distribution_mode, "shared"),
      queues: queues
    }
  end

  defp put_timing(row, rows, collected_at) do
    row
    |> Map.put(
      :oldest_available_age_seconds,
      timing(rows, "available", :scheduled_at, collected_at, :age)
    )
    |> Map.put(
      :oldest_executing_age_seconds,
      timing(rows, "executing", :attempted_at, collected_at, :age)
    )
    |> Map.put(
      :oldest_retryable_age_seconds,
      timing(rows, "retryable", :attempted_at, collected_at, :age)
    )
    |> Map.put(
      :next_scheduled_in_seconds,
      timing(rows, "scheduled", :scheduled_at, collected_at, :until)
    )
  end

  defp timing(rows, state, field, collected_at, mode) do
    case Enum.find(rows, &(&1.state == state)) do
      %{count: count} when count > 0 ->
        item =
          rows
          |> Enum.filter(&(&1.state == state))
          |> Enum.sort_by(&nullable_timestamp(&1, field))
          |> List.first()

        timing_value(item, field, collected_at, mode)

      _ ->
        0
    end
  end

  defp collected_at_diff(collected_at, timestamp),
    do: max(DateTime.diff(collected_at, timestamp, :microsecond) / 1_000_000, 0)

  defp timing_value(nil, _field, _collected_at, _mode), do: 0

  defp timing_value(item, field, collected_at, mode) do
    case Map.get(item, field) do
      %DateTime{} = timestamp ->
        delta = DateTime.diff(timestamp, collected_at, :microsecond) / 1_000_000
        if mode == :age, do: collected_at_diff(collected_at, timestamp), else: max(delta, 0)

      _ ->
        0
    end
  end

  defp nullable_timestamp(item, field) do
    case Map.get(item, field) do
      %DateTime{} = timestamp -> DateTime.to_unix(timestamp, :microsecond)
      _ -> 9_223_372_036_854_775_807
    end
  end

  defp active_row([queue, state, count, min_scheduled_at, min_attempted_at]),
    do:
      active_row(%{
        queue: queue,
        state: state,
        count: count,
        min_scheduled_at: min_scheduled_at,
        min_attempted_at: min_attempted_at
      })

  defp active_row(row), do: normalize_active(row)

  defp discarded_row([queue, count]), do: discarded_row(%{queue: queue, count: count})
  defp discarded_row(row), do: normalize_discarded(row)

  defp normalize_active(row) do
    %{
      queue: normalize_queue(Map.get(row, :queue, Map.get(row, "queue"))),
      state: to_string(Map.get(row, :state, Map.get(row, "state"))),
      count: Map.get(row, :count, Map.get(row, "count", 0)),
      scheduled_at:
        normalize_timestamp(Map.get(row, :min_scheduled_at, Map.get(row, "min_scheduled_at"))),
      attempted_at:
        normalize_timestamp(Map.get(row, :min_attempted_at, Map.get(row, "min_attempted_at")))
    }
  end

  defp normalize_discarded(row) do
    %{
      queue: normalize_queue(Map.get(row, :queue, Map.get(row, "queue"))),
      count: Map.get(row, :count, Map.get(row, "count", 0))
    }
  end

  defp normalize_timestamp(%DateTime{} = value), do: value
  defp normalize_timestamp(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp normalize_timestamp(value), do: value

  defp normalize_queue(queue) when queue in @configured_queues, do: queue
  defp normalize_queue(_queue), do: "__unexpected__"

  defp repo_query(repo, sql, params) do
    repo.query(sql, params)
  rescue
    UndefinedFunctionError ->
      repo.query(sql, params, [])
  end
end
