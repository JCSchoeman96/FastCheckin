defmodule FastCheck.Sales.Inventory.ReservationLedger do
  @moduledoc """
  Redis-backed hot inventory mutation boundary for FastCheck Sales.

  This module enforces fail-closed behavior when Redis is unavailable.
  It does not use Repo/Ash/TicketOffer reads in hot operations.
  """

  alias FastCheck.Sales.Inventory.RedisScripts

  @expire_batch_size 100

  @type availability_snapshot :: %{
          offer_id: integer(),
          configured_quantity: integer(),
          available_quantity: integer(),
          reserved_quantity: integer(),
          consumed_quantity: integer(),
          ledger_state: atom(),
          revision: integer(),
          updated_at: integer() | nil
        }

  @spec initialize_offer(integer(), integer()) :: :ok | {:error, atom(), map()}
  def initialize_offer(offer_id, configured_quantity)
      when is_integer(offer_id) and is_integer(configured_quantity) do
    if configured_quantity < 0 do
      {:error, :invalid_quantity, %{offer_id: offer_id}}
    else
      now = now_ms()

      command_result(
        [
          "HSET",
          inventory_key(offer_id),
          "offer_id",
          Integer.to_string(offer_id),
          "configured_quantity",
          Integer.to_string(configured_quantity),
          "available_quantity",
          Integer.to_string(configured_quantity),
          "reserved_quantity",
          "0",
          "consumed_quantity",
          "0",
          "revision",
          "1",
          "ledger_state",
          "healthy",
          "updated_at",
          Integer.to_string(now)
        ],
        offer_id
      )
      |> case do
        {:ok, _} -> :ok
        {:error, _atom, _meta} = error -> error
      end
    end
  end

  def initialize_offer(offer_id, _configured_quantity),
    do: {:error, :invalid_quantity, %{offer_id: offer_id}}

  @spec reserve(integer(), String.t(), integer(), integer(), String.t()) ::
          {:ok, map()} | {:error, atom(), map()}
  def reserve(offer_id, order_public_reference, quantity, ttl_seconds, idempotency_key) do
    with :ok <- validate_positive(quantity, :invalid_quantity, offer_id),
         :ok <- validate_ttl(ttl_seconds, offer_id),
         :ok <- validate_idempotency(idempotency_key, offer_id) do
      now = now_ms()

      RedisScripts.reserve(
        offer_id: offer_id,
        keys: [
          inventory_key(offer_id),
          holds_key(offer_id),
          hold_key(order_public_reference),
          dedupe_key(:reserve, idempotency_key),
          order_lock_key(order_public_reference)
        ],
        argv: [
          Integer.to_string(offer_id),
          order_public_reference,
          Integer.to_string(quantity),
          Integer.to_string(ttl_seconds),
          idempotency_key,
          Integer.to_string(now),
          args_sig("reserve", [offer_id, order_public_reference, quantity, ttl_seconds]),
          Integer.to_string(RedisScripts.dedupe_ttl_seconds()),
          Integer.to_string(RedisScripts.order_lock_ttl_ms())
        ]
      )
      |> map_hold_snapshot(offer_id, order_public_reference, quantity)
    end
  end

  @spec consume(integer(), String.t(), integer(), String.t()) ::
          {:ok, map()} | {:error, atom(), map()}
  def consume(offer_id, order_public_reference, quantity, idempotency_key) do
    with :ok <- validate_positive(quantity, :invalid_quantity, offer_id),
         :ok <- validate_idempotency(idempotency_key, offer_id) do
      RedisScripts.consume(
        offer_id: offer_id,
        keys: [
          inventory_key(offer_id),
          holds_key(offer_id),
          hold_key(order_public_reference),
          dedupe_key(:consume, idempotency_key),
          order_lock_key(order_public_reference)
        ],
        argv: [
          order_public_reference,
          Integer.to_string(quantity),
          Integer.to_string(now_ms()),
          args_sig("consume", [offer_id, order_public_reference, quantity]),
          Integer.to_string(RedisScripts.dedupe_ttl_seconds()),
          Integer.to_string(RedisScripts.order_lock_ttl_ms())
        ]
      )
      |> map_hold_snapshot(offer_id, order_public_reference, quantity)
    end
  end

  @spec release(integer(), String.t(), String.t()) :: {:ok, map()} | {:error, atom(), map()}
  def release(offer_id, order_public_reference, idempotency_key) do
    with :ok <- validate_idempotency(idempotency_key, offer_id) do
      RedisScripts.release(
        offer_id: offer_id,
        keys: [
          inventory_key(offer_id),
          holds_key(offer_id),
          hold_key(order_public_reference),
          dedupe_key(:release, idempotency_key),
          order_lock_key(order_public_reference)
        ],
        argv: [
          order_public_reference,
          Integer.to_string(now_ms()),
          args_sig("release", [offer_id, order_public_reference]),
          Integer.to_string(RedisScripts.dedupe_ttl_seconds()),
          Integer.to_string(RedisScripts.order_lock_ttl_ms())
        ]
      )
      |> map_release_snapshot(offer_id, order_public_reference)
    end
  end

  @spec expire_due_holds(integer()) ::
          {:ok,
           %{expired_count: non_neg_integer(), skipped_count: non_neg_integer(), errors: list()}}
          | {:error, atom(), map()}
  def expire_due_holds(now) when is_integer(now) do
    offer_ids = discover_offer_ids()

    Enum.reduce_while(
      offer_ids,
      {:ok, %{expired_count: 0, skipped_count: 0, errors: []}},
      fn offer_id, {:ok, acc} ->
        case expire_due_holds_for_offer(offer_id, now) do
          {:ok, partial} ->
            merged = %{
              acc
              | expired_count: acc.expired_count + partial.expired_count,
                skipped_count: acc.skipped_count + partial.skipped_count,
                errors: partial.errors ++ acc.errors
            }

            {:cont, {:ok, merged}}

          {:error, atom, meta} ->
            {:halt, {:error, atom, meta}}
        end
      end
    )
  end

  @spec expire_due_holds_for_offer(integer(), integer()) ::
          {:ok,
           %{expired_count: non_neg_integer(), skipped_count: non_neg_integer(), errors: list()}}
          | {:error, atom(), map()}
  def expire_due_holds_for_offer(offer_id, now)
      when is_integer(offer_id) and is_integer(now) do
    case command_result(
           [
             "ZRANGEBYSCORE",
             holds_key(offer_id),
             "-inf",
             Integer.to_string(now),
             "LIMIT",
             "0",
             Integer.to_string(@expire_batch_size)
           ],
           offer_id
         ) do
      {:ok, due_refs} when is_list(due_refs) ->
        acc =
          Enum.reduce(due_refs, %{expired_count: 0, skipped_count: 0, errors: []}, fn ref, acc ->
            expire_one_for_hold(offer_id, ref, now, acc)
          end)

        {:ok, acc}

      {:error, atom, meta} ->
        {:error, atom, meta}
    end
  end

  @spec mark_offer_health(integer(), atom(), String.t() | nil) :: :ok | {:error, atom(), map()}
  def mark_offer_health(offer_id, health_state, _reason)
      when is_integer(offer_id) and
             health_state in [
               :healthy,
               :degraded,
               :reconciliation_required,
               :closed,
               :rebuilding
             ] do
    now = now_ms()
    state_string = Atom.to_string(health_state)

    with {:ok, revision} <- current_revision(offer_id),
         {:ok, _} <-
           command_result(
             [
               "HSET",
               inventory_key(offer_id),
               "ledger_state",
               state_string,
               "revision",
               Integer.to_string(revision + 1),
               "updated_at",
               Integer.to_string(now)
             ],
             offer_id
           ) do
      :ok
    else
      {:error, _atom, _meta} = error -> error
    end
  end

  def mark_offer_health(offer_id, _health_state, _reason),
    do: {:error, :reconciliation_required, %{offer_id: offer_id}}

  @type rebuild_counts :: %{
          required(:configured_quantity) => non_neg_integer(),
          required(:available_quantity) => non_neg_integer(),
          required(:reserved_quantity) => non_neg_integer(),
          required(:consumed_quantity) => non_neg_integer(),
          optional(:ledger_state) => atom()
        }

  @spec rebuild_inventory(integer(), rebuild_counts()) :: :ok | {:error, atom(), map()}
  def rebuild_inventory(offer_id, counts) when is_integer(offer_id) and is_map(counts) do
    now = now_ms()
    ledger_state = Map.get(counts, :ledger_state, :reconciliation_required)
    state_string = Atom.to_string(ledger_state)

    with {:ok, revision} <- current_revision(offer_id),
         {:ok, _} <-
           command_result(
             [
               "HSET",
               inventory_key(offer_id),
               "offer_id",
               Integer.to_string(offer_id),
               "configured_quantity",
               Integer.to_string(counts.configured_quantity),
               "available_quantity",
               Integer.to_string(counts.available_quantity),
               "reserved_quantity",
               Integer.to_string(counts.reserved_quantity),
               "consumed_quantity",
               Integer.to_string(counts.consumed_quantity),
               "ledger_state",
               state_string,
               "revision",
               Integer.to_string(revision + 1),
               "updated_at",
               Integer.to_string(now),
               "last_reconciled_at",
               Integer.to_string(now)
             ],
             offer_id
           ) do
      :ok
    else
      {:error, _atom, _meta} = error -> error
    end
  end

  defp current_revision(offer_id) do
    case command_result(["HGET", inventory_key(offer_id), "revision"], offer_id) do
      {:ok, nil} -> {:ok, 0}
      {:ok, revision} -> {:ok, parse_int(revision)}
      {:error, _atom, _meta} = error -> error
    end
  end

  @spec get_availability(integer()) :: {:ok, availability_snapshot()} | {:error, atom(), map()}
  def get_availability(offer_id) when is_integer(offer_id) do
    case command_result(
           [
             "HMGET",
             inventory_key(offer_id),
             "configured_quantity",
             "available_quantity",
             "reserved_quantity",
             "consumed_quantity",
             "ledger_state",
             "revision",
             "updated_at"
           ],
           offer_id
         ) do
      {:ok, [nil, nil, nil, nil, nil, nil, nil]} ->
        {:error, :reconciliation_required, %{offer_id: offer_id}}

      {:ok, [configured, available, reserved, consumed, ledger_state, revision, updated_at]} ->
        {:ok,
         %{
           offer_id: offer_id,
           configured_quantity: parse_int(configured),
           available_quantity: parse_int(available),
           reserved_quantity: parse_int(reserved),
           consumed_quantity: parse_int(consumed),
           ledger_state: parse_ledger_state(ledger_state),
           revision: parse_int(revision),
           updated_at: parse_int(updated_at)
         }}

      {:error, atom, meta} ->
        {:error, atom, meta}
    end
  end

  defp expire_one_for_hold(offer_id, order_ref, now, acc) do
    case RedisScripts.expire_one(
           offer_id: offer_id,
           keys: [
             inventory_key(offer_id),
             holds_key(offer_id),
             hold_key(order_ref),
             order_lock_key(order_ref)
           ],
           argv: [
             order_ref,
             Integer.to_string(now),
             Integer.to_string(RedisScripts.order_lock_ttl_ms())
           ]
         ) do
      {:ok, %{expired: true}} ->
        %{acc | expired_count: acc.expired_count + 1}

      {:ok, %{skipped: _}} ->
        %{acc | skipped_count: acc.skipped_count + 1}

      {:error, atom, meta} ->
        %{acc | errors: [%{offer_id: offer_id, error: atom, meta: meta} | acc.errors]}
    end
  end

  defp map_hold_snapshot({:ok, payload}, offer_id, order_public_reference, quantity) do
    snapshot = %{
      offer_id: offer_id,
      order_public_reference: order_public_reference,
      quantity: quantity,
      status: payload.status,
      expires_at: payload.expires_at,
      revision: payload.revision
    }

    if Map.get(payload, :idempotent) do
      {:ok, Map.put(snapshot, :idempotent, true)}
    else
      {:ok, snapshot}
    end
  end

  defp map_hold_snapshot({:error, :hold_not_found, _meta}, offer_id, _order_ref, _quantity),
    do: {:error, :hold_not_found, %{offer_id: offer_id}}

  defp map_hold_snapshot({:error, :hold_expired, _meta}, offer_id, _order_ref, _quantity),
    do: {:error, :hold_expired, %{offer_id: offer_id}}

  defp map_hold_snapshot({:error, atom, meta}, _offer_id, _order_ref, _quantity),
    do: {:error, atom, meta}

  defp map_release_snapshot({:ok, payload}, offer_id, order_public_reference) do
    snapshot = %{
      offer_id: offer_id,
      order_public_reference: order_public_reference,
      status: payload.status,
      revision: payload.revision
    }

    if Map.get(payload, :idempotent) do
      {:ok, Map.put(snapshot, :idempotent, true)}
    else
      {:ok, snapshot}
    end
  end

  defp map_release_snapshot({:error, atom, meta}, _offer_id, _order_ref), do: {:error, atom, meta}

  defp command_result(command, offer_id) do
    case Process.whereis(FastCheck.Redix) do
      pid when is_pid(pid) ->
        case Redix.command(FastCheck.Redix, command) do
          {:ok, value} ->
            {:ok, value}

          {:error, reason} ->
            {:error, :ledger_unavailable, %{offer_id: offer_id, reason: inspect(reason)}}
        end

      _ ->
        {:error, :ledger_unavailable, %{offer_id: offer_id, reason: "redis_process_missing"}}
    end
  end

  defp discover_offer_ids do
    do_discover_offer_ids("0", [])
    |> Enum.uniq()
  end

  defp do_discover_offer_ids(cursor, acc) do
    case command_result(["SCAN", cursor, "MATCH", "sales:offer:*:holds", "COUNT", "1000"], nil) do
      {:ok, [next_cursor, keys]} ->
        found =
          keys
          |> Enum.map(fn key ->
            case String.split(key, ":") do
              ["sales", "offer", offer_id, "holds"] -> String.to_integer(offer_id)
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        merged = found ++ acc

        if next_cursor == "0" do
          merged
        else
          do_discover_offer_ids(next_cursor, merged)
        end

      _ ->
        acc
    end
  end

  defp validate_positive(value, _error_atom, _offer_id) when is_integer(value) and value > 0,
    do: :ok

  defp validate_positive(_value, error_atom, offer_id),
    do: {:error, error_atom, %{offer_id: offer_id}}

  defp validate_ttl(value, _offer_id) when is_integer(value) and value > 0, do: :ok

  defp validate_ttl(_value, offer_id),
    do: {:error, :invalid_quantity, %{offer_id: offer_id, field: :ttl_seconds}}

  defp validate_idempotency(value, offer_id) when is_binary(value) do
    if String.trim(value) == "",
      do: {:error, :invalid_idempotency_key, %{offer_id: offer_id}},
      else: :ok
  end

  defp validate_idempotency(_value, offer_id),
    do: {:error, :invalid_idempotency_key, %{offer_id: offer_id}}

  defp parse_int(nil), do: 0

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp parse_ledger_state("healthy"), do: :healthy
  defp parse_ledger_state("degraded"), do: :degraded
  defp parse_ledger_state("reconciliation_required"), do: :reconciliation_required
  defp parse_ledger_state("closed"), do: :closed
  defp parse_ledger_state("rebuilding"), do: :reconciliation_required
  defp parse_ledger_state(_), do: :reconciliation_required

  defp args_sig(operation, parts), do: Enum.join([operation | Enum.map(parts, &to_string/1)], "|")

  defp inventory_key(offer_id), do: "sales:offer:#{offer_id}:inventory"
  defp holds_key(offer_id), do: "sales:offer:#{offer_id}:holds"

  @doc """
  Returns the canonical Redis hold key for an order public reference.
  """
  @spec hold_key(String.t()) :: String.t()
  def hold_key(order_public_reference) when is_binary(order_public_reference),
    do: "sales:hold:#{order_public_reference}"

  defp order_lock_key(order_public_reference), do: "sales:order:#{order_public_reference}:lock"

  defp dedupe_key(operation, idempotency_key),
    do: "sales:inventory:dedupe:#{operation}:#{idempotency_key}"

  defp now_ms, do: System.system_time(:millisecond)
end
