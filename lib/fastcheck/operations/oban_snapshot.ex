defmodule FastCheck.Operations.ObanSnapshot do
  @moduledoc """
  Safe, bounded data used by the global Oban monitoring projection.
  """

  @version 1
  @configured_queues ~w(
    scan_persistence
    sales_inventory
    payments
    ticketing
    sales_maintenance
    whatsapp_inbound
    whatsapp_outbound
  )
  @queue_labels @configured_queues ++ ["__unexpected__"]
  @states ~w(available executing retryable scheduled)

  @type queue_row :: %{
          queue: String.t(),
          available: non_neg_integer(),
          executing: non_neg_integer(),
          retryable: non_neg_integer(),
          scheduled: non_neg_integer(),
          discarded_recent_count: non_neg_integer(),
          oldest_available_age_seconds: number(),
          oldest_executing_age_seconds: number(),
          oldest_retryable_age_seconds: number(),
          next_scheduled_in_seconds: number(),
          configured_limit: non_neg_integer() | nil,
          configured?: boolean()
        }

  @spec version() :: pos_integer()
  def version, do: @version

  @spec configured_queues() :: [String.t()]
  def configured_queues, do: @configured_queues

  @spec queue_labels() :: [String.t()]
  def queue_labels, do: @queue_labels

  @spec states() :: [String.t()]
  def states, do: @states

  @spec configured_limit(String.t()) :: non_neg_integer() | nil
  def configured_limit(queue) when queue in @configured_queues do
    queues =
      Application.get_env(:fastcheck, Oban, [])
      |> Keyword.get(:queues, [])

    queues = if is_list(queues), do: queues, else: []

    queues
    |> Enum.find_value(fn
      {^queue, limit} when is_integer(limit) and limit >= 0 -> limit
      _ -> nil
    end)
    |> case do
      nil -> default_limit(queue)
      limit -> limit
    end
  end

  def configured_limit(_queue), do: nil

  @spec empty_row(String.t()) :: queue_row()
  def empty_row(queue) do
    %{
      queue: queue,
      available: 0,
      executing: 0,
      retryable: 0,
      scheduled: 0,
      discarded_recent_count: 0,
      oldest_available_age_seconds: 0,
      oldest_executing_age_seconds: 0,
      oldest_retryable_age_seconds: 0,
      next_scheduled_in_seconds: 0,
      configured_limit: configured_limit(queue),
      configured?: queue in @configured_queues
    }
  end

  @spec normalize(term()) :: {:ok, map()} | {:error, atom()}
  def normalize(snapshot) when is_map(snapshot) do
    if safe_snapshot_keys?(snapshot) do
      with {:ok, version} <- value(snapshot, :version),
           true <- version == @version,
           {:ok, collected_at} <- collected_at(snapshot),
           {:ok, queues} <- normalize_queues(value_or(snapshot, :queues, [])),
           {:ok, collector_node} <- safe_string(value_or(snapshot, :collector_node, "unknown")),
           {:ok, distribution_mode} <-
             safe_string(value_or(snapshot, :distribution_mode, "shared")) do
        {:ok,
         %{
           version: @version,
           collected_at: collected_at,
           collector_node: collector_node,
           distribution_mode: distribution_mode,
           queues: queues
         }}
      else
        false -> {:error, :unsupported_version}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_snapshot}
      end
    else
      {:error, :invalid_snapshot_shape}
    end
  end

  def normalize(_snapshot), do: {:error, :invalid_snapshot}

  defp normalize_queues(queues) when is_list(queues) do
    rows =
      queues
      |> Enum.reduce(%{}, fn row, acc ->
        case normalize_row(row) do
          {:ok, normalized} -> Map.put(acc, normalized.queue, normalized)
          :error -> acc
        end
      end)

    if map_size(rows) == length(queues) do
      {:ok, Enum.map(@queue_labels, &Map.get(rows, &1, empty_row(&1)))}
    else
      {:error, :invalid_snapshot_shape}
    end
  end

  defp normalize_queues(queues) when is_map(queues) do
    if Enum.all?(queues, fn {_queue, row} -> is_map(row) end) do
      queues
      |> Enum.map(fn {queue, row} -> Map.put(row, :queue, queue) end)
      |> normalize_queues()
    else
      {:error, :invalid_snapshot_shape}
    end
  end

  defp normalize_queues(_queues), do: {:error, :invalid_snapshot_shape}

  defp normalize_row(row) when is_map(row) do
    if safe_row_keys?(row) do
      queue = value_or(row, :queue, value_or(row, :name, nil))

      if queue in @queue_labels do
        with {:ok, available} <- non_neg_int(row, :available),
             {:ok, executing} <- non_neg_int(row, :executing),
             {:ok, retryable} <- non_neg_int(row, :retryable),
             {:ok, scheduled} <- non_neg_int(row, :scheduled),
             {:ok, discarded} <- non_neg_int(row, :discarded_recent_count),
             {:ok, oldest_available} <- non_neg_number(row, :oldest_available_age_seconds),
             {:ok, oldest_executing} <- non_neg_number(row, :oldest_executing_age_seconds),
             {:ok, oldest_retryable} <- non_neg_number(row, :oldest_retryable_age_seconds),
             {:ok, next_scheduled} <- non_neg_number(row, :next_scheduled_in_seconds),
             {:ok, _configured_limit} <- optional_non_neg_int(row, :configured_limit),
             {:ok, _configured?} <- boolean_value(row, :configured?) do
          {:ok,
           %{
             queue: queue,
             available: available,
             executing: executing,
             retryable: retryable,
             scheduled: scheduled,
             discarded_recent_count: discarded,
             oldest_available_age_seconds: if(available == 0, do: 0, else: oldest_available),
             oldest_executing_age_seconds: if(executing == 0, do: 0, else: oldest_executing),
             oldest_retryable_age_seconds: if(retryable == 0, do: 0, else: oldest_retryable),
             next_scheduled_in_seconds: if(scheduled == 0, do: 0, else: next_scheduled),
             configured_limit:
               if(queue in @configured_queues,
                 do: configured_limit(queue),
                 else: nil
               ),
             configured?: queue in @configured_queues
           }}
        else
          _ -> :error
        end
      else
        :error
      end
    else
      :error
    end
  end

  defp normalize_row(_row), do: :error

  defp collected_at(snapshot) do
    case value(snapshot, :collected_at) do
      {:ok, %DateTime{} = value} -> {:ok, value}
      {:ok, value} when is_binary(value) -> DateTime.from_iso8601(value) |> iso8601_result()
      _ -> {:error, :invalid_collected_at}
    end
  end

  defp iso8601_result({:ok, value, _offset}), do: {:ok, value}
  defp iso8601_result(_), do: {:error, :invalid_collected_at}

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp value_or(map, key, default) do
    case value(map, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp non_neg_int(map, key) do
    case value(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      {:ok, value} when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= 0 -> {:ok, parsed}
          _ -> {:error, :invalid_snapshot_shape}
        end

      _ ->
        {:error, :invalid_snapshot_shape}
    end
  end

  defp optional_non_neg_int(map, key) do
    case value(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_snapshot_shape}
    end
  end

  defp non_neg_number(map, key) do
    case value(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, value} when is_float(value) and value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_snapshot_shape}
    end
  end

  defp boolean_value(map, key) do
    case value(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      :error -> {:ok, false}
      _ -> {:error, :invalid_snapshot_shape}
    end
  end

  defp safe_string(value) when is_binary(value) and byte_size(value) <= 256, do: {:ok, value}
  defp safe_string(_value), do: {:error, :invalid_snapshot_shape}

  defp safe_snapshot_keys?(snapshot) do
    Enum.all?(
      Map.keys(snapshot),
      &key_in?(&1, ~w(version collected_at collector_node distribution_mode queues freshness))
    )
  end

  defp safe_row_keys?(row) do
    Enum.all?(
      Map.keys(row),
      &key_in?(
        &1,
        ~w(queue name available executing retryable scheduled discarded_recent_count oldest_available_age_seconds oldest_executing_age_seconds oldest_retryable_age_seconds next_scheduled_in_seconds configured_limit configured?)
      )
    )
  end

  defp key_in?(key, allowed) when is_atom(key), do: Atom.to_string(key) in allowed
  defp key_in?(key, allowed) when is_binary(key), do: key in allowed
  defp key_in?(_key, _allowed), do: false

  defp default_limit("scan_persistence"), do: 10
  defp default_limit("sales_inventory"), do: 5
  defp default_limit("payments"), do: 5
  defp default_limit("ticketing"), do: 5
  defp default_limit("sales_maintenance"), do: 3
  defp default_limit("whatsapp_inbound"), do: 5
  defp default_limit("whatsapp_outbound"), do: 5
end
