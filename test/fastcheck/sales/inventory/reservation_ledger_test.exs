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

  test "reserve with different idempotency key for same order does not double-decrement availability",
       %{run_id: run_id} do
    order_ref = "ORD-DEDUP-REF"

    assert {:ok, first} =
             ReservationLedger.reserve(@offer_id, order_ref, 2, 120, idem("idem-a", run_id))

    assert first.status == :held

    assert {:ok, snapshot} = ReservationLedger.get_availability(@offer_id)
    assert snapshot.available_quantity == 8
    assert snapshot.reserved_quantity == 2

    assert {:ok, second} =
             ReservationLedger.reserve(@offer_id, order_ref, 2, 120, idem("idem-b", run_id))

    assert second.status == :held
    assert second.idempotent == true

    assert {:ok, snapshot_after} = ReservationLedger.get_availability(@offer_id)
    assert snapshot_after.available_quantity == 8
    assert snapshot_after.reserved_quantity == 2
  end

  test "reserve with different idempotency key and different quantity returns quantity_mismatch",
       %{run_id: run_id} do
    order_ref = "ORD-DEDUP-QTY"

    assert {:ok, _} =
             ReservationLedger.reserve(@offer_id, order_ref, 2, 120, idem("idem-qty-a", run_id))

    assert {:error, :invalid_quantity, %{reason: :quantity_mismatch}} =
             ReservationLedger.reserve(@offer_id, order_ref, 3, 120, idem("idem-qty-b", run_id))

    assert {:ok, snapshot} = ReservationLedger.get_availability(@offer_id)
    assert snapshot.available_quantity == 8
    assert snapshot.reserved_quantity == 2
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

  test "checkout compensation releases and clears matching reserve dedupe atomically", %{
    run_id: run_id
  } do
    order_ref = "ORD-COMPENSATE-#{run_id}"
    reserve_key = idem("idem-checkout-comp", run_id)
    compensation_key = "checkout-compensate-#{order_ref}"
    reserve_dedupe_key = reserve_dedupe_key(reserve_key)

    assert {:ok, held} = ReservationLedger.reserve(@offer_id, order_ref, 2, 120, reserve_key)
    assert held.status == :held
    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["EXISTS", reserve_dedupe_key])

    assert {:ok, released} =
             ReservationLedger.compensate_checkout_reservation(
               @offer_id,
               order_ref,
               2,
               120,
               reserve_key,
               compensation_key
             )

    assert released.status == :released
    assert {:ok, 0} = Redix.command(FastCheck.Redix, ["EXISTS", reserve_dedupe_key])

    assert {:ok, replayed_compensation} =
             ReservationLedger.compensate_checkout_reservation(
               @offer_id,
               order_ref,
               2,
               120,
               reserve_key,
               compensation_key
             )

    assert replayed_compensation.idempotent
    assert replayed_compensation.status == :released
    assert replayed_compensation == Map.put(released, :idempotent, true)

    assert {:ok, retried_hold} =
             ReservationLedger.reserve(
               @offer_id,
               "ORD-COMPENSATE-RETRY-#{run_id}",
               2,
               120,
               reserve_key
             )

    assert retried_hold.status == :held
    assert {:ok, snapshot} = ReservationLedger.get_availability(@offer_id)
    assert snapshot.available_quantity == 8
    assert snapshot.reserved_quantity == 2
  end

  test "checkout compensation supports an existing hold without ttl metadata", %{run_id: run_id} do
    order_ref = "ORD-COMPENSATE-LEGACY-#{run_id}"
    reserve_key = idem("idem-checkout-legacy", run_id)

    assert {:ok, _held} = ReservationLedger.reserve(@offer_id, order_ref, 1, 120, reserve_key)

    assert {:ok, _} =
             Redix.command(FastCheck.Redix, [
               "HDEL",
               ReservationLedger.hold_key(order_ref),
               "ttl_seconds"
             ])

    assert {:ok, nil} =
             Redix.command(FastCheck.Redix, [
               "HGET",
               ReservationLedger.hold_key(order_ref),
               "ttl_seconds"
             ])

    assert {:ok, %{status: :released}} =
             ReservationLedger.compensate_checkout_reservation(
               @offer_id,
               order_ref,
               1,
               120,
               reserve_key,
               "checkout-compensate-legacy-#{run_id}"
             )

    assert {:ok, 0} =
             Redix.command(FastCheck.Redix, ["EXISTS", reserve_dedupe_key(reserve_key)])
  end

  test "checkout compensation preserves malformed reserve dedupe state", %{run_id: run_id} do
    order_ref = "ORD-COMPENSATE-MALFORMED-#{run_id}"
    reserve_key = idem("idem-checkout-malformed", run_id)
    reserve_key_name = reserve_dedupe_key(reserve_key)

    assert {:ok, _held} = ReservationLedger.reserve(@offer_id, order_ref, 1, 120, reserve_key)
    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["HDEL", reserve_key_name, "args_sig"])
    before = availability!()

    assert {:error, :checkout_reservation_mismatch, _meta} =
             ReservationLedger.compensate_checkout_reservation(
               @offer_id,
               order_ref,
               1,
               120,
               reserve_key,
               "checkout-compensate-malformed-#{run_id}"
             )

    assert availability!() == before
    assert {:ok, %{status: :held}} = ReservationLedger.get_hold_detail(@offer_id, order_ref)
    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["EXISTS", reserve_key_name])
    assert {:ok, nil} = Redix.command(FastCheck.Redix, ["HGET", reserve_key_name, "args_sig"])
  end

  test "checkout compensation fails before mutation when the holds index has the wrong type", %{
    run_id: run_id
  } do
    order_ref = "ORD-COMPENSATE-BAD-INDEX-#{run_id}"
    reserve_key = idem("idem-checkout-bad-index", run_id)
    compensation_key = "checkout-compensate-bad-index-#{run_id}"
    reserve_key_name = reserve_dedupe_key(reserve_key)
    compensation_key_name = "sales:inventory:dedupe:checkout_compensation:#{compensation_key}"

    assert {:ok, _held} = ReservationLedger.reserve(@offer_id, order_ref, 1, 120, reserve_key)
    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["DEL", holds_key(@offer_id)])

    assert {:ok, "OK"} =
             Redix.command(FastCheck.Redix, ["SET", holds_key(@offer_id), "wrong-type"])

    before = availability!()

    assert {:error, :unexpected_redis_response, _meta} =
             ReservationLedger.compensate_checkout_reservation(
               @offer_id,
               order_ref,
               1,
               120,
               reserve_key,
               compensation_key
             )

    assert availability!() == before
    assert {:ok, %{status: :held}} = ReservationLedger.get_hold_detail(@offer_id, order_ref)
    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["EXISTS", reserve_key_name])
    assert {:ok, 0} = Redix.command(FastCheck.Redix, ["EXISTS", compensation_key_name])
  end

  test "checkout compensation rejects a different checkout idempotency key", %{run_id: run_id} do
    order_ref = "ORD-COMPENSATE-OWNER-#{run_id}"
    reserve_key = idem("idem-checkout-owner", run_id)
    reserve_dedupe_key = reserve_dedupe_key(reserve_key)

    assert {:ok, _held} = ReservationLedger.reserve(@offer_id, order_ref, 1, 120, reserve_key)
    before = availability!()

    assert {:error, :checkout_reservation_mismatch, _meta} =
             ReservationLedger.compensate_checkout_reservation(
               @offer_id,
               order_ref,
               1,
               120,
               idem("idem-checkout-wrong-owner", run_id),
               "checkout-compensate-wrong-owner-#{run_id}"
             )

    assert availability!() == before
    assert {:ok, %{status: :held}} = ReservationLedger.get_hold_detail(@offer_id, order_ref)
    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["EXISTS", reserve_dedupe_key])
  end

  test "checkout compensation cannot clear a reserve from another reference or offer", %{
    run_id: run_id
  } do
    order_ref = "ORD-COMPENSATE-SCOPE-#{run_id}"
    reserve_key = idem("idem-checkout-scope", run_id)
    compensation_key = "checkout-compensate-scope-#{run_id}"
    reserve_dedupe_key = reserve_dedupe_key(reserve_key)
    other_offer_id = 45_000 + run_id

    :ok = flush_offer_inventory(other_offer_id)
    :ok = ReservationLedger.initialize_offer(other_offer_id, 5)
    on_exit(fn -> flush_offer_inventory(other_offer_id) end)

    assert {:ok, _held} = ReservationLedger.reserve(@offer_id, order_ref, 1, 120, reserve_key)
    before = availability!()

    assert {:error, :hold_not_found, _meta} =
             ReservationLedger.compensate_checkout_reservation(
               @offer_id,
               "ORD-COMPENSATE-UNRELATED-#{run_id}",
               1,
               120,
               reserve_key,
               compensation_key
             )

    assert {:error, :checkout_reservation_mismatch, _meta} =
             ReservationLedger.compensate_checkout_reservation(
               other_offer_id,
               order_ref,
               1,
               120,
               reserve_key,
               compensation_key
             )

    assert availability!() == before
    assert {:ok, %{status: :held}} = ReservationLedger.get_hold_detail(@offer_id, order_ref)
    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["EXISTS", reserve_dedupe_key])
    assert {:ok, other_snapshot} = ReservationLedger.get_availability(other_offer_id)
    assert other_snapshot.available_quantity == 5
    assert other_snapshot.reserved_quantity == 0
  end

  test "checkout compensation fails closed for consumed released and expired holds", %{
    run_id: run_id
  } do
    consumed_ref = "ORD-COMPENSATE-CONSUMED-#{run_id}"
    consumed_key = idem("idem-checkout-consumed", run_id)

    assert {:ok, _} = ReservationLedger.reserve(@offer_id, consumed_ref, 1, 120, consumed_key)

    assert {:ok, _} =
             ReservationLedger.consume(
               @offer_id,
               consumed_ref,
               1,
               idem("idem-checkout-consume", run_id)
             )

    assert {:error, :already_consumed, _meta} =
             ReservationLedger.compensate_checkout_reservation(
               @offer_id,
               consumed_ref,
               1,
               120,
               consumed_key,
               "checkout-compensate-consumed-#{run_id}"
             )

    released_ref = "ORD-COMPENSATE-RELEASED-#{run_id}"
    released_key = idem("idem-checkout-released", run_id)

    assert {:ok, _} = ReservationLedger.reserve(@offer_id, released_ref, 1, 120, released_key)

    assert {:ok, _} =
             ReservationLedger.release(
               @offer_id,
               released_ref,
               idem("idem-checkout-normal-release", run_id)
             )

    assert {:error, :already_released, _meta} =
             ReservationLedger.compensate_checkout_reservation(
               @offer_id,
               released_ref,
               1,
               120,
               released_key,
               "checkout-compensate-released-#{run_id}"
             )

    expired_ref = "ORD-COMPENSATE-EXPIRED-#{run_id}"
    expired_key = idem("idem-checkout-expired", run_id)

    assert {:ok, _} = ReservationLedger.reserve(@offer_id, expired_ref, 1, 1, expired_key)
    Process.sleep(1_100)

    assert {:ok, %{expired_count: 1, errors: []}} =
             ReservationLedger.expire_due_holds(System.system_time(:millisecond))

    assert {:error, :hold_expired, _meta} =
             ReservationLedger.compensate_checkout_reservation(
               @offer_id,
               expired_ref,
               1,
               1,
               expired_key,
               "checkout-compensate-expired-#{run_id}"
             )
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
    scan_delete_all("sales:hold:*")
    scan_delete_all("sales:order:*:lock")
    scan_delete_all("sales:inventory:dedupe:*")
    :ok
  end

  defp scan_delete_all(pattern) do
    do_scan_delete_all("0", pattern)
  end

  defp do_scan_delete_all(cursor, pattern) do
    case Redix.command(FastCheck.Redix, ["SCAN", cursor, "MATCH", pattern, "COUNT", "500"]) do
      {:ok, [next_cursor, keys]} ->
        if keys != [], do: _ = Redix.command(FastCheck.Redix, ["DEL" | keys])

        if next_cursor == "0" do
          :ok
        else
          do_scan_delete_all(next_cursor, pattern)
        end

      _ ->
        :ok
    end
  end

  defp inventory_key(offer_id), do: "sales:offer:#{offer_id}:inventory"
  defp holds_key(offer_id), do: "sales:offer:#{offer_id}:holds"
  defp event_trail_key(offer_id), do: "sales:inventory:events:#{offer_id}"
  defp order_lock_key(order_ref), do: "sales:order:#{order_ref}:lock"

  defp reserve_dedupe_key(idempotency_key),
    do: "sales:inventory:dedupe:reserve:#{idempotency_key}"

  defp availability! do
    assert {:ok, snapshot} = ReservationLedger.get_availability(@offer_id)
    snapshot
  end

  defp flush_offer_inventory(offer_id) do
    _ =
      Redix.command(FastCheck.Redix, [
        "DEL",
        inventory_key(offer_id),
        holds_key(offer_id),
        event_trail_key(offer_id)
      ])

    :ok
  end

  defp idem(base, run_id), do: "#{base}-#{run_id}"
end
