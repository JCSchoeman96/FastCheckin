defmodule FastCheck.Sales.Inventory.ReservationLedgerTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.Inventory.ReservationLedger

  @offer_id 44_001
  @base_quantity 10

  setup do
    run_id = System.unique_integer([:positive])
    flush_inventory_keys(@offer_id)
    :ok = ReservationLedger.initialize_offer(@offer_id, @base_quantity)
    on_exit(fn -> flush_inventory_keys(@offer_id) end)
    {:ok, run_id: run_id}
  end

  test "reserve returns reconciliation_required when inventory hash is missing", %{run_id: run_id} do
    assert {:ok, _} = ReservationLedger.get_availability(@offer_id)
    assert {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", inventory_key(@offer_id)])

    assert {:error, :reconciliation_required, _meta} =
             ReservationLedger.reserve(
               @offer_id,
               "ORD-1",
               1,
               120,
               idem("reserve-missing-hash", run_id)
             )
  end

  test "reserve and consume are idempotent with same idempotency key", %{run_id: run_id} do
    reserve_key = idem("idem-reserve-1", run_id)
    consume_key = idem("idem-consume-1", run_id)

    assert {:ok, held} = ReservationLedger.reserve(@offer_id, "ORD-2", 2, 120, reserve_key)
    assert held.status == :held

    assert {:ok, held_replay} = ReservationLedger.reserve(@offer_id, "ORD-2", 2, 120, reserve_key)

    assert held_replay.status == :held
    assert held_replay.idempotent == true

    assert {:ok, consumed} = ReservationLedger.consume(@offer_id, "ORD-2", 2, consume_key)
    assert consumed.status == :consumed

    assert {:ok, consumed_replay} = ReservationLedger.consume(@offer_id, "ORD-2", 2, consume_key)

    assert consumed_replay.status == :consumed
    assert consumed_replay.idempotent == true
  end

  test "duplicate idempotency key with conflicting args returns invalid_idempotency_key", %{
    run_id: run_id
  } do
    conflict_key = idem("idem-conflict-1", run_id)
    assert {:ok, _held} = ReservationLedger.reserve(@offer_id, "ORD-3", 1, 120, conflict_key)

    assert {:error, :invalid_idempotency_key, %{reason: :duplicate_conflict}} =
             ReservationLedger.reserve(@offer_id, "ORD-3", 2, 120, conflict_key)
  end

  test "invalid ttl returns invalid_quantity with ttl_seconds field", %{run_id: run_id} do
    assert {:error, :invalid_quantity, %{field: :ttl_seconds}} =
             ReservationLedger.reserve(@offer_id, "ORD-TTL", 1, 0, idem("idem-ttl", run_id))
  end

  test "release is idempotent and cannot release consumed hold", %{run_id: run_id} do
    assert {:ok, _held} =
             ReservationLedger.reserve(@offer_id, "ORD-4", 1, 120, idem("idem-rel-1", run_id))

    assert {:ok, released} =
             ReservationLedger.release(@offer_id, "ORD-4", idem("idem-rel-2", run_id))

    assert released.status == :released

    assert {:ok, replayed_release} =
             ReservationLedger.release(@offer_id, "ORD-4", idem("idem-rel-2", run_id))

    assert replayed_release.status == :released
    assert replayed_release.idempotent == true

    assert {:error, :already_released, _meta} =
             ReservationLedger.release(@offer_id, "ORD-4", idem("idem-rel-fresh", run_id))

    assert {:ok, _held2} =
             ReservationLedger.reserve(@offer_id, "ORD-5", 1, 120, idem("idem-rel-3", run_id))

    assert {:ok, _consumed2} =
             ReservationLedger.consume(@offer_id, "ORD-5", 1, idem("idem-rel-4", run_id))

    assert {:error, :already_consumed, _meta} =
             ReservationLedger.release(@offer_id, "ORD-5", idem("idem-rel-5", run_id))
  end

  test "fresh release against expired hold returns hold_expired", %{run_id: run_id} do
    assert {:ok, _held} =
             ReservationLedger.reserve(@offer_id, "ORD-EXP", 1, 1, idem("idem-exp-rel", run_id))

    Process.sleep(1100)

    assert {:ok, %{expired_count: 1, errors: []}} =
             ReservationLedger.expire_due_holds(System.system_time(:millisecond))

    assert {:error, :hold_expired, _meta} =
             ReservationLedger.release(@offer_id, "ORD-EXP", idem("idem-exp-rel-fresh", run_id))
  end

  test "lock contention returns lock_timeout", %{run_id: run_id} do
    order_ref = "ORD-LOCK"
    lock_key = order_lock_key(order_ref)

    assert {:ok, "OK"} =
             Redix.command(FastCheck.Redix, ["SET", lock_key, "1", "NX", "PX", "30000"])

    assert {:error, :lock_timeout, _meta} =
             ReservationLedger.reserve(@offer_id, order_ref, 1, 120, idem("idem-lock", run_id))

    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["DEL", lock_key])
  end

  test "expire_due_holds expires due held reservations and skips consumed holds", %{
    run_id: run_id
  } do
    assert {:ok, _held} =
             ReservationLedger.reserve(@offer_id, "ORD-6", 1, 1, idem("idem-exp-1", run_id))

    assert {:ok, _held2} =
             ReservationLedger.reserve(@offer_id, "ORD-7", 1, 120, idem("idem-exp-2", run_id))

    assert {:ok, _consumed2} =
             ReservationLedger.consume(@offer_id, "ORD-7", 1, idem("idem-exp-3", run_id))

    Process.sleep(1100)

    assert {:ok, %{expired_count: 1, skipped_count: skipped, errors: []}} =
             ReservationLedger.expire_due_holds(System.system_time(:millisecond))

    assert skipped >= 0
    assert {:ok, snapshot} = ReservationLedger.get_availability(@offer_id)
    assert snapshot.available_quantity >= 9
  end

  defp flush_inventory_keys(offer_id) do
    keys = [
      inventory_key(offer_id),
      holds_key(offer_id),
      event_trail_key(offer_id)
    ]

    _ = Redix.command(FastCheck.Redix, ["DEL" | keys])

    case Redix.command(FastCheck.Redix, ["SCAN", "0", "MATCH", "sales:hold:*", "COUNT", "500"]) do
      {:ok, [_cursor, hold_keys]} when hold_keys != [] ->
        _ = Redix.command(FastCheck.Redix, ["DEL" | hold_keys])
        :ok

      _ ->
        :ok
    end

    case Redix.command(FastCheck.Redix, [
           "SCAN",
           "0",
           "MATCH",
           "sales:order:*:lock",
           "COUNT",
           "500"
         ]) do
      {:ok, [_cursor, lock_keys]} when lock_keys != [] ->
        _ = Redix.command(FastCheck.Redix, ["DEL" | lock_keys])
        :ok

      _ ->
        :ok
    end
  end

  defp inventory_key(offer_id), do: "sales:offer:#{offer_id}:inventory"
  defp holds_key(offer_id), do: "sales:offer:#{offer_id}:holds"
  defp event_trail_key(offer_id), do: "sales:inventory:events:#{offer_id}"
  defp order_lock_key(order_ref), do: "sales:order:#{order_ref}:lock"
  defp idem(base, run_id), do: "#{base}-#{run_id}"
end
