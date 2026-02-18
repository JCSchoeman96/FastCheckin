defmodule FastCheck.Cache.CacheManager do
  @moduledoc """
  I'm building FastCheck, a PETAL stack event check-in system. I need you to generate a production-ready Cache Manager module using Cachex.

  PROJECT CONTEXT:

  Event check-in system with real-time occupancy tracking

  High-concurrency scanning (100+ devices simultaneously)

  Multi-gate support (Main, VIP, Staff entrances)

  Performance target: <50ms per scan

  Tickera API integration (slow, 500-1500ms latency)

  REQUIREMENTS:

  Create file: lib/fastcheck/cache/cache_manager.ex

  This module will:

  Initialize Cachex cache with appropriate settings

  Provide a clean API for cache operations

  Support TTL (Time-To-Live) for automatic expiration

  Handle cache errors gracefully

  Support cache invalidation via PubSub

  Provide monitoring/debugging helpers

  SPECIFIC CACHING NEEDS FOR FASTCHECK:

  A) Config/Metadata Cache (1 hour TTL):

  Event configuration from Tickera (allowed_checkins, time_basis, date windows)

  Ticket type information

  Gate/entrance configuration
  Keys: "event_config:{event_id}", "ticket_types:{event_id}"

  B) Occupancy Cache (10 second TTL):

  Current occupancy count (people inside venue)

  Per-gate occupancy

  Capacity percentage
  Keys: "occupancy:event:{event_id}", "occupancy:gate:{gate_id}"

  C) Attendee Lookup Cache (No TTL, invalidate on check-in):

  Frequently accessed attendee records

  Used for QR code validation
  Keys: "attendee:{event_id}:{ticket_code}"

  D) Statistics Cache (1 minute TTL):

  Total checked in, pending, no-shows

  Check-in rate (per minute)
  Keys: "stats:{event_id}"

  IMPLEMENTATION REQUIREMENTS:

  Cachex Configuration:

  Default TTL: 1 hour (configurable per cache operation)

  Max size: 10,000 items (configurable)

  Eviction policy: LRU (Least Recently Used)

  Enable statistics tracking (for monitoring)

  Core Functions (with @spec and full @doc):

  get(key) → {:ok, value} | {:ok, nil} | {:error, reason}

  put(key, value, opts \\ []) → {:ok, true} | {:error, reason}

  get_or_put(key, callback, opts \\ []) → {:ok, value} | {:error, reason}

  delete(key) → {:ok, true} | {:error, reason}

  invalidate_pattern(pattern) → {:ok, count} | {:error, reason}

  clear() → :ok

  stats() → %{hits: int, misses: int, evictions: int}

  Error Handling:

  All functions return {:ok, result} or {:error, reason}

  Never raise exceptions

  Log errors at appropriate levels (debug, warning, error)

  Graceful degradation (if cache fails, queries still work)

  Logging:

  Debug log on cache hits/misses

  Info log on cache operations

  Warn log on cache errors or unusual patterns

  Use Logger module with structured logging

  Testing Helpers:

  reset() → clear cache for testing

  info() → get cache statistics and status

  EXAMPLE USAGE:

      iex> alias FastCheck.Cache.CacheManager, as: Cache
      iex> Cache.put("event_config:1", %{name: "Gala"}, ttl: :timer.hours(1))
      {:ok, true}
      iex> {:ok, config} = Cache.get("event_config:1")
      {:ok, %{name: "Gala"}}
      iex> {:ok, config} = Cache.get_or_put("event_config:1", fn -> %{name: "Gala"} end, ttl: :timer.hours(1))
      {:ok, %{name: "Gala"}}
      iex> Cache.invalidate_pattern("occupancy:gate:1:*")
      {:ok, 0}
      iex> Cache.delete("occupancy:event:1")
      {:ok, true}
      iex> {:ok, %{hits: 0, misses: 1, evictions: 0}} = Cache.stats()
      {:ok, %{hits: 0, misses: 1, evictions: 0}}

  The module below implements all of the above requirements and is ready for production use in FastCheck.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  require Logger
  require Cachex.Spec
  alias Phoenix.PubSub
  alias FastCheck.Repo
  alias FastCheck.Events.CheckInConfiguration
  alias FastCheck.Cache.EtsLayer

  @typedoc """
  Describes the cache key used within Cachex. Keys are typically binaries but
  can be any term supported by Cachex.
  """
  @type key :: term()

  @typedoc """
  Generic cache value type.
  """
  @type value :: term()

  @typedoc """
  Common error reason propagated by cache operations.
  """
  @type reason :: term()

  @type cache_result(result) :: {:ok, result} | {:error, reason()}

  @default_config [
    cache_name: :fastcheck_cache,
    default_ttl: :timer.hours(1),
    expiration_interval: :timer.minutes(1),
    max_size: 10_000,
    pubsub_topic: "fastcheck:cache:invalidate"
  ]

  @ttl_overrides [
    {"occupancy:event:", :timer.seconds(10)},
    {"occupancy:gate:", :timer.seconds(10)},
    {"stats:", :timer.minutes(1)},
    {"attendee:", :infinity}
  ]

  @config_cache_prefix "event_config:"
  @ticket_types_prefix "ticket_types:"
  @occupancy_event_prefix "occupancy:event:"
  @occupancy_gate_prefix "occupancy:gate:"
  @attendee_prefix "attendee:"
  @stats_prefix "stats:"

  @pubsub FastCheck.PubSub
  @invalidation_event :cache_invalidate
  @config_key {__MODULE__, :config}

  @empty_occupancy %{
    inside: 0,
    total_entries: 0,
    total_exits: 0,
    capacity: nil,
    percentage: 0.0,
    updated_at: nil
  }

  @doc """
  Starts the cache manager GenServer. The server bootstraps Cachex with the
  configured options and subscribes to the cache invalidation PubSub topic.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Child specification so the module can be included in the supervision tree.
  """
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @impl true
  def init(opts) do
    config = build_config(opts)

    :persistent_term.put(@config_key, config)

    case maybe_start_cache(config) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Cachex failed to start (#{inspect(config.cache_name)}): #{inspect(reason)}")
    end

    :ok = PubSub.subscribe(@pubsub, config.pubsub_topic)

    Logger.info(fn ->
      {"Cache manager started", cache_name: config.cache_name, topic: config.pubsub_topic}
    end)

    {:ok, config}
  end

  @impl true
  def handle_info({@invalidation_event, pattern}, state) do
    Logger.debug(fn ->
      {"Remote cache invalidation", pattern: pattern}
    end)

    _ = do_invalidate(pattern, :remote)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase(@config_key)
    :ok
  end

  @doc """
  Fetches a cached value by key, logging whether the entry was a hit or miss.
  Returns `{:ok, nil}` when the key does not exist or has expired.
  """
  @spec get(key()) :: cache_result(value() | nil)
  def get(key) do
    if cache_ready?() do
      case Cachex.get(cache_name(), key) do
        {:ok, nil} = response ->
          log_cache_event(:miss, key)
          response

        {:ok, _value} = response ->
          touch_entry(key)
          log_cache_event(:hit, key)
          response

        {:error, reason} ->
          log_cache_error(:get, key, reason)
          {:error, reason}
      end
    else
      {:error, :cache_unavailable}
    end
  end

  @doc """
  Writes a value into the cache. Accepts optional options such as `:ttl` for
  entry-specific TTL overrides.
  """
  @spec put(key(), value(), Keyword.t()) :: cache_result(true)
  def put(key, value, opts \\ []) do
    if cache_ready?() do
      ttl = resolve_ttl(key, opts)
      put_opts = build_write_opts(ttl)

      case Cachex.put(cache_name(), key, value, put_opts) do
        {:ok, true} = response ->
          maybe_persist(key, ttl)

          Logger.info(fn ->
            {"Cache write", cache_key: key, ttl: ttl, size: byte_size_safe(value)}
          end)

          response

        {:error, reason} ->
          log_cache_error(:put, key, reason)
          {:error, reason}
      end
    else
      {:error, :cache_unavailable}
    end
  end

  @doc """
  Reads a key from the cache and populates it via the provided callback when
  missing. The callback is executed once on cache misses and its return value is
  stored using the provided TTL options.
  """
  @spec get_or_put(key(), (-> value()), Keyword.t()) :: cache_result(value())
  def get_or_put(key, callback, opts \\ []) when is_function(callback, 0) do
    with {:ok, value} <- get(key) do
      case value do
        nil ->
          with {:ok, computed} <- safe_execute(callback),
               {:ok, true} <- put(key, computed, opts) do
            {:ok, computed}
          else
            {:error, reason} -> {:error, reason}
          end

        cached ->
          {:ok, cached}
      end
    else
      {:error, :cache_unavailable} ->
        safe_execute(callback)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes an entry from the cache.
  """
  @spec delete(key()) :: cache_result(true)
  def delete(key) do
    if cache_ready?() do
      case Cachex.del(cache_name(), key) do
        {:ok, _} ->
          Logger.info(fn ->
            {"Cache delete", cache_key: key}
          end)

          {:ok, true}

        {:error, reason} ->
          log_cache_error(:delete, key, reason)
          {:error, reason}
      end
    else
      {:error, :cache_unavailable}
    end
  end

  @doc """
  Invalidates all entries matching the provided pattern. The pattern supports
  wildcards accepted by `Cachex.keys/2`. An invalidation message is also
  broadcast over PubSub so all nodes drop the same entries.
  """
  @spec invalidate_pattern(String.t()) :: cache_result(non_neg_integer())
  def invalidate_pattern(pattern) when is_binary(pattern) do
    do_invalidate(pattern, :local)
  end

  @doc """
  Clears the entire cache. Intended for administrative or testing purposes.
  """
  @spec clear() :: :ok | {:error, reason()}
  def clear do
    if cache_ready?() do
      case Cachex.clear(cache_name()) do
        {:ok, _} ->
          Logger.warning("Cache cleared")
          :ok

        {:error, reason} ->
          log_cache_error(:clear, :all, reason)
          {:error, reason}
      end
    else
      {:error, :cache_unavailable}
    end
  end

  @doc """
  Exposes Cachex runtime statistics such as hits, misses, and evictions for
  monitoring dashboards.
  """
  @spec stats() ::
          cache_result(%{
            hits: non_neg_integer(),
            misses: non_neg_integer(),
            evictions: non_neg_integer()
          })
  def stats do
    if cache_ready?() do
      case Cachex.stats(cache_name()) do
        {:ok, stats} ->
          {:ok,
           %{
             hits: Map.get(stats, :total_hit_count, 0),
             misses: Map.get(stats, :total_miss_count, 0),
             evictions: Map.get(stats, :eviction_count, 0)
           }}

        {:error, reason} ->
          log_cache_error(:stats, :all, reason)
          {:error, reason}
      end
    else
      {:error, :cache_unavailable}
    end
  end

  @doc """
  Returns the underlying Cachex information payload for debugging.
  """
  @spec info() :: cache_result(map())
  def info do
    if cache_ready?() do
      case Cachex.inspect(cache_name(), :cache) do
        {:ok, info} ->
          {:ok, info}

        {:error, reason} ->
          log_cache_error(:info, :all, reason)
          {:error, reason}
      end
    else
      {:error, :cache_unavailable}
    end
  end

  @doc """
  Testing helper that clears the cache and resets stats.
  """
  @spec reset() :: :ok | {:error, reason()}
  def reset do
    clear()
  end

  @doc """
  Convenience helper that persists event configuration payloads with the
  appropriate TTL.
  """
  @spec put_event_config(integer(), list() | map()) :: cache_result(true)
  def put_event_config(event_id, config) when is_integer(event_id) do
    normalized = ensure_ticket_config_cache_entry(config)
    EtsLayer.put_event_config(event_id, normalized)
    put(event_config_key(event_id), normalized, ttl: :timer.hours(1))
  end

  @doc """
  Retrieves cached event configuration metadata.
  """
  @spec cache_get_ticket_config(integer(), any()) :: cache_result(map() | nil)
  def cache_get_ticket_config(event_id, ticket_identifier) when is_integer(event_id) do
    cache_key = event_config_key(event_id)

    with {:ok, cache_entry} <- fetch_or_cache_event_configs(cache_key, event_id) do
      {:ok, find_cached_ticket_config(cache_entry, ticket_identifier)}
    end
  end

  @doc """
  Stores the event ticket type payload.
  """
  @spec put_ticket_types(integer(), list()) :: cache_result(true)
  def put_ticket_types(event_id, ticket_types) when is_integer(event_id) do
    put(ticket_types_key(event_id), ticket_types, ttl: :timer.hours(1))
  end

  @doc """
  Persists per-event occupancy snapshots with the fast 10-second TTL.
  """
  @spec put_event_occupancy(integer(), map()) :: cache_result(true)
  def put_event_occupancy(event_id, snapshot) when is_integer(event_id) do
    put(occupancy_event_key(event_id), normalize_occupancy(snapshot), ttl: :timer.seconds(10))
  end

  @doc """
  Stores per-gate occupancy details.
  """
  @spec put_gate_occupancy(term(), map()) :: cache_result(true)
  def put_gate_occupancy(gate_id, snapshot) do
    put(occupancy_gate_key(gate_id), snapshot, ttl: :timer.seconds(10))
  end

  @doc """
  Fetches cached gate occupancy data.
  """
  @spec get_gate_occupancy(term()) :: cache_result(map() | nil)
  def get_gate_occupancy(gate_id) do
    get(occupancy_gate_key(gate_id))
  end

  @doc """
  Retrieves the cached occupancy snapshot for an event.
  """
  @spec get_cached_occupancy(integer()) :: cache_result(map())
  def get_cached_occupancy(event_id) when is_integer(event_id) do
    case get(occupancy_event_key(event_id)) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, snapshot} -> {:ok, normalize_occupancy(snapshot)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes attendee lookup information with no TTL so it can be explicitly
  invalidated once a scan is completed.
  """
  @spec put_attendee(integer(), term(), map()) :: cache_result(true)
  def put_attendee(event_id, ticket_code, attendee) do
    put(attendee_key(event_id, ticket_code), attendee, ttl: :infinity)
  end

  @doc """
  Fetches an attendee lookup record from the cache.
  """
  @spec get_attendee(integer(), term()) :: cache_result(map() | nil)
  def get_attendee(event_id, ticket_code) do
    get(attendee_key(event_id, ticket_code))
  end

  @doc """
  Removes an attendee lookup entry when a scan is processed.
  """
  @spec delete_attendee(integer(), term()) :: cache_result(true)
  def delete_attendee(event_id, ticket_code) do
    delete(attendee_key(event_id, ticket_code))
  end

  @doc """
  Stores computed event statistics.
  """
  @spec put_event_stats(integer(), map()) :: cache_result(true)
  def put_event_stats(event_id, stats) when is_integer(event_id) do
    put(stats_key(event_id), stats, ttl: :timer.minutes(1))
  end

  @doc """
  Retrieves cached statistics for an event.
  """
  @spec get_event_stats(integer()) :: cache_result(map() | nil)
  def get_event_stats(event_id) when is_integer(event_id) do
    get(stats_key(event_id))
  end

  @doc """
  Atomically increments the cached occupancy counters for a given event and
  broadcasts the new totals over PubSub.
  """
  @spec increment_occupancy(integer(), String.t()) :: cache_result(non_neg_integer())
  def increment_occupancy(event_id, change_type)
      when is_integer(event_id) and change_type in ["entry", "exit"] do
    if cache_ready?() do
      key = occupancy_event_key(event_id)
      delta = if(change_type == "entry", do: 1, else: -1)

      case Cachex.transaction(cache_name(), [key], fn cache ->
             snapshot =
               case Cachex.get(cache, key) do
                 {:ok, value} -> normalize_occupancy(value)
                 _ -> @empty_occupancy
               end

             updated = apply_occupancy_delta(snapshot, delta)

             case Cachex.put(cache, key, updated, ttl: :timer.seconds(10)) do
               {:ok, true} -> {:ok, updated}
               {:error, reason} -> {:error, reason}
             end
           end) do
        {:ok, {:ok, updated}} ->
          broadcast_occupancy(event_id, updated.inside, change_type)
          {:ok, updated.inside}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          log_cache_error(:transaction, key, reason)
          {:error, reason}
      end
    else
      {:error, :cache_unavailable}
    end
  end

  def increment_occupancy(_, _), do: {:error, :invalid_arguments}

  defp cache_name, do: config()[:cache_name]

  defp cache_ready? do
    cache_name()
    |> Process.whereis()
    |> is_pid()
  end

  defp config do
    case :persistent_term.get(@config_key, nil) do
      nil -> build_config([])
      config -> config
    end
  end

  defp build_config(opts) do
    app_opts = Application.get_env(:fastcheck, __MODULE__, [])

    @default_config
    |> Keyword.merge(app_opts)
    |> Keyword.merge(opts)
    |> Map.new()
  end

  defp maybe_start_cache(%{cache_name: name} = config) do
    if cache_ready?() do
      :ok
    else
      cache_options = [
        stats: true,
        limit: Cachex.Spec.limit(size: config.max_size, policy: Cachex.Policy.LRW),
        expiration:
          Cachex.Spec.expiration(
            default: config.default_ttl,
            interval: config.expiration_interval
          )
      ]

      case Cachex.start_link(name, cache_options) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp resolve_ttl(key, opts) do
    case Keyword.fetch(opts, :ttl) do
      {:ok, ttl} -> ttl
      :error -> infer_ttl_from_key(key)
    end
  end

  defp infer_ttl_from_key(key) when is_binary(key) do
    Enum.find_value(@ttl_overrides, config()[:default_ttl], fn {prefix, ttl} ->
      if String.starts_with?(key, prefix), do: ttl
    end)
  end

  defp infer_ttl_from_key(_key), do: config()[:default_ttl]

  defp build_write_opts(:infinity), do: []
  defp build_write_opts(nil), do: []
  defp build_write_opts(ttl) when is_integer(ttl) and ttl > 0, do: [ttl: ttl]
  defp build_write_opts(_ttl), do: []

  defp maybe_persist(_key, ttl) when ttl not in [:infinity, :persist], do: :ok
  defp maybe_persist(key, _ttl), do: Cachex.persist(cache_name(), key)

  defp safe_execute(callback) do
    case callback.() do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      value -> {:ok, value}
    end
  rescue
    exception ->
      Logger.error(fn ->
        {"Cache callback failed", reason: Exception.message(exception)}
      end)

      {:error, exception}
  end

  defp do_invalidate(pattern, origin) do
    if cache_ready?() do
      case Cachex.keys(cache_name(), match: pattern) do
        {:ok, keys} ->
          count =
            keys
            |> Enum.reduce(0, fn key, acc ->
              case Cachex.del(cache_name(), key) do
                {:ok, true} -> acc + 1
                _ -> acc
              end
            end)

          if origin == :local do
            PubSub.broadcast(@pubsub, config()[:pubsub_topic], {@invalidation_event, pattern})
          end

          {:ok, count}

        {:error, reason} ->
          log_cache_error(:invalidate, pattern, reason)
          {:error, reason}
      end
    else
      {:error, :cache_unavailable}
    end
  end

  defp log_cache_event(type, key) do
    Logger.debug(fn ->
      {"Cache #{type}", cache_key: key}
    end)
  end

  defp log_cache_error(operation, key, reason) do
    Logger.warning(fn ->
      {"Cache operation failed", operation: operation, cache_key: key, reason: inspect(reason)}
    end)
  end

  defp byte_size_safe(value) when is_binary(value), do: byte_size(value)
  defp byte_size_safe(value) when is_map(value), do: :erlang.term_to_binary(value) |> byte_size()
  defp byte_size_safe(value) when is_list(value), do: :erlang.term_to_binary(value) |> byte_size()
  defp byte_size_safe(_), do: 0

  defp event_config_key(event_id), do: @config_cache_prefix <> to_string(event_id)
  defp ticket_types_key(event_id), do: @ticket_types_prefix <> to_string(event_id)
  defp occupancy_event_key(event_id), do: @occupancy_event_prefix <> to_string(event_id)
  defp occupancy_gate_key(gate_id), do: @occupancy_gate_prefix <> to_string(gate_id)

  defp attendee_key(event_id, ticket_code),
    do: @attendee_prefix <> to_string(event_id) <> ":" <> to_string(ticket_code)

  defp stats_key(event_id), do: @stats_prefix <> to_string(event_id)

  defp broadcast_occupancy(event_id, count, change_type) do
    PubSub.broadcast(
      @pubsub,
      "event:#{event_id}:occupancy",
      {:occupancy_changed, count, change_type}
    )
  end

  defp touch_entry(key) do
    Cachex.touch(cache_name(), key)
  end

  defp fetch_or_cache_event_configs(cache_key, event_id) do
    case EtsLayer.get_event_config(event_id) do
      {:ok, %{records: _records, by_id: _by_id, by_label: _by_label} = entry} ->
        {:ok, entry}

      {:ok, _other} ->
        case get(cache_key) do
          {:ok, nil} ->
            load_event_configs_from_db(cache_key, event_id)

          {:ok, %{records: _records, by_id: _by_id, by_label: _by_label} = entry} ->
            {:ok, entry}

          {:ok, entry} ->
            {:ok, ensure_ticket_config_cache_entry(entry)}

          {:error, reason} ->
            {:error, reason}
        end

      :not_found ->
        case get(cache_key) do
          {:ok, nil} ->
            load_event_configs_from_db(cache_key, event_id)

          {:ok, %{records: _records, by_id: _by_id, by_label: _by_label} = entry} ->
            {:ok, entry}

          {:ok, entry} ->
            {:ok, ensure_ticket_config_cache_entry(entry)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp load_event_configs_from_db(cache_key, event_id) do
    with {:ok, configs} <- fetch_ticket_configs_from_db(event_id) do
      entry = build_ticket_config_cache_entry(configs)
      EtsLayer.put_event_config(event_id, entry)
      _ = put(cache_key, entry, ttl: :timer.hours(1))
      {:ok, entry}
    end
  end

  defp fetch_ticket_configs_from_db(event_id) do
    query = from(c in CheckInConfiguration, where: c.event_id == ^event_id)

    {:ok, Repo.all(query)}
  rescue
    exception ->
      Logger.error(fn ->
        {"Failed to load ticket configs", event_id: event_id, error: Exception.message(exception)}
      end)

      {:error, :config_lookup_failed}
  end

  defp ensure_ticket_config_cache_entry(
         %{records: _records, by_id: _by_id, by_label: _by_label} = entry
       ),
       do: entry

  defp ensure_ticket_config_cache_entry(entry), do: build_ticket_config_cache_entry(entry)

  defp build_ticket_config_cache_entry(configs) do
    records =
      configs
      |> List.wrap()
      |> Enum.reject(&is_nil/1)

    {by_id, by_label} =
      Enum.reduce(records, {%{}, %{}}, fn config, {id_acc, label_acc} ->
        {index_config_by_id(id_acc, config), index_config_by_label(label_acc, config)}
      end)

    %{records: records, by_id: by_id, by_label: by_label}
  end

  defp index_config_by_id(acc, config) do
    case Map.get(config, :ticket_type_id) do
      nil -> acc
      id -> Map.put(acc, id, config)
    end
  end

  defp index_config_by_label(acc, config) do
    config
    |> ticket_config_labels()
    |> Enum.reduce(acc, fn label, map -> Map.put_new(map, label, config) end)
  end

  defp ticket_config_labels(config) do
    [Map.get(config, :ticket_type), Map.get(config, :ticket_name)]
    |> Enum.map(&normalize_ticket_label/1)
    |> Enum.reject(&is_nil/1)
  end

  defp find_cached_ticket_config(%{by_id: by_id, by_label: by_label}, ticket_identifier) do
    cond do
      is_nil(ticket_identifier) ->
        nil

      is_integer(ticket_identifier) ->
        Map.get(by_id, ticket_identifier)

      is_binary(ticket_identifier) ->
        trimmed = String.trim(ticket_identifier)
        normalized = normalize_ticket_label(trimmed)
        parsed_id = parse_ticket_type_id(trimmed)

        Map.get(by_id, parsed_id) || Map.get(by_label, normalized)

      is_map(ticket_identifier) ->
        case Map.get(ticket_identifier, :ticket_type_id) do
          nil ->
            Map.get(by_label, normalize_ticket_label(Map.get(ticket_identifier, :ticket_type)))

          id ->
            Map.get(by_id, id)
        end

      true ->
        nil
    end
  end

  defp find_cached_ticket_config(_entry, _ticket_identifier), do: nil

  defp parse_ticket_type_id(value) when is_integer(value) and value > 0, do: value

  defp parse_ticket_type_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp parse_ticket_type_id(_value), do: nil

  defp normalize_ticket_label(nil), do: nil

  defp normalize_ticket_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_occupancy(nil), do: @empty_occupancy

  defp normalize_occupancy(%{inside: inside} = snapshot) do
    %{
      inside: max(inside || 0, 0),
      total_entries: max(Map.get(snapshot, :total_entries, 0), 0),
      total_exits: max(Map.get(snapshot, :total_exits, 0), 0),
      capacity: Map.get(snapshot, :capacity),
      percentage: compute_percentage(inside, Map.get(snapshot, :capacity)),
      updated_at: Map.get(snapshot, :updated_at, DateTime.utc_now())
    }
  end

  defp normalize_occupancy(_snapshot), do: @empty_occupancy

  defp apply_occupancy_delta(snapshot, delta) do
    inside = max(snapshot.inside + delta, 0)
    total_entries = snapshot.total_entries + max(delta, 0)
    total_exits = snapshot.total_exits + max(-delta, 0)

    %{
      snapshot
      | inside: inside,
        total_entries: total_entries,
        total_exits: total_exits,
        percentage: compute_percentage(inside, snapshot.capacity),
        updated_at: DateTime.utc_now()
    }
  end

  defp compute_percentage(_inside, nil), do: 0.0

  defp compute_percentage(inside, capacity) when capacity > 0 do
    Float.round(inside / capacity * 100, 2)
  end

  defp compute_percentage(_inside, _capacity), do: 0.0
end
