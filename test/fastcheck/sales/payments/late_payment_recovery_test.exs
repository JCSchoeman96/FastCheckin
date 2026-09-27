defmodule FastCheck.Sales.Payments.LatePaymentRecoveryTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Payments.LatePaymentRecovery
  alias FastCheck.Sales.Payments.PaymentFailureReason
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!()
    :ok = ReservationLedger.initialize_offer(offer.id, 2)

    on_exit(fn ->
      Fixtures.flush_inventory_keys(offer.id)
      Application.delete_env(:fastcheck, :late_payment_recovery_mark_paid_fun)
    end)

    {:ok, offer: offer}
  end

  test "releases reserved inventory when paid transition fails before consume", %{offer: offer} do
    ctx =
      LatePaymentRecovery.build_ctx(101, offer.id, "ORD-LATE-1", 1)

    Application.put_env(
      :fastcheck,
      :late_payment_recovery_mark_paid_fun,
      fn -> {:error, :forced_db_failure} end
    )

    reason = PaymentFailureReason.late_payment_recovery_failed()

    assert {:error, :manual_review, ^reason} =
             LatePaymentRecovery.recover(ctx, fn -> {:error, :forced_db_failure} end)

    assert {:ok, availability} = ReservationLedger.get_availability(offer.id)
    assert availability.available_quantity == 2
  end

  test "late-payment recovery can retry after a failed paid transition releases its hold", %{
    offer: offer
  } do
    order_ref = "ORD-LATE-RETRY-RELEASED"
    ctx = LatePaymentRecovery.build_ctx(105, offer.id, order_ref, 1)

    assert {:ok, _original_hold} =
             ReservationLedger.reserve(
               offer.id,
               order_ref,
               1,
               ctx.ttl_seconds,
               "checkout-original-reservation"
             )

    assert {:error, :manual_review, _reason} =
             LatePaymentRecovery.recover(ctx, fn -> {:error, :forced_db_failure} end)

    assert {:ok, %{status: :released}} =
             ReservationLedger.get_hold_detail(offer.id, order_ref)

    reserve_dedupe_key = "sales:inventory:dedupe:reserve:#{ctx.reserve_key}"
    release_dedupe_key = "sales:inventory:dedupe:release:#{ctx.release_key}"

    assert {:ok, 0} = Redix.command(FastCheck.Redix, ["EXISTS", reserve_dedupe_key])
    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["EXISTS", release_dedupe_key])

    assert {:ok, :paid} = LatePaymentRecovery.recover(ctx, fn -> {:ok, :paid} end)

    assert {:ok, %{status: :held, quantity: 1}} =
             ReservationLedger.get_hold_detail(offer.id, order_ref)

    assert {:ok, %{available_quantity: 1, reserved_quantity: 1, consumed_quantity: 0}} =
             ReservationLedger.get_availability(offer.id)
  end

  test "failed hold release keeps the recovery retryable", %{offer: offer} do
    ctx = LatePaymentRecovery.build_ctx(108, offer.id, "ORD-LATE-RELEASE-FAILURE", 1)

    Application.put_env(:fastcheck, :late_payment_recovery_mark_paid_fun, fn ->
      Fixtures.stop_redis_connection!()
      {:error, :forced_db_failure}
    end)

    try do
      assert {:error, :retryable} =
               LatePaymentRecovery.recover(ctx, fn -> {:error, :forced_db_failure} end)
    after
      Fixtures.start_redis_connection!()
    end

    assert {:ok, %{available_quantity: 1, reserved_quantity: 1, consumed_quantity: 0}} =
             ReservationLedger.get_availability(offer.id)

    assert {:ok, %{status: :held, quantity: 1}} =
             ReservationLedger.get_hold_detail(offer.id, ctx.order_ref)
  end

  test "unsafe hold release marks the offer for reconciliation", %{offer: offer} do
    ctx = LatePaymentRecovery.build_ctx(109, offer.id, "ORD-LATE-UNSAFE-RELEASE", 1)

    Application.put_env(:fastcheck, :late_payment_recovery_mark_paid_fun, fn ->
      assert {:ok, _} =
               Redix.command(FastCheck.Redix, [
                 "HSET",
                 ReservationLedger.hold_key(ctx.order_ref),
                 "offer_id",
                 Integer.to_string(offer.id + 1)
               ])

      {:error, :forced_db_failure}
    end)

    assert {:error, :manual_review, reason} =
             LatePaymentRecovery.recover(ctx, fn -> {:error, :forced_db_failure} end)

    assert reason == PaymentFailureReason.late_payment_inventory_ledger_unhealthy()

    assert {:ok, %{ledger_state: :reconciliation_required, reserved_quantity: 1}} =
             ReservationLedger.get_availability(offer.id)
  end

  test "transient reserve failure is retryable before paid state is committed", %{offer: offer} do
    ctx = LatePaymentRecovery.build_ctx(106, offer.id, "ORD-LATE-RETRY-RESERVE", 1)

    Fixtures.with_redis_stopped(fn ->
      assert {:error, :retryable} = LatePaymentRecovery.recover(ctx, fn -> {:ok, :paid} end)
    end)

    assert {:ok, %{available_quantity: 2, reserved_quantity: 0, consumed_quantity: 0}} =
             ReservationLedger.get_availability(offer.id)
  end

  test "successful recovery leaves its hold for PaidOrderFulfillment", %{offer: offer} do
    ctx = LatePaymentRecovery.build_ctx(102, offer.id, "ORD-LATE-2", 1)
    paid_result = %{order_id: 55, session_id: 66}

    assert {:ok, ^paid_result} = LatePaymentRecovery.recover(ctx, fn -> {:ok, paid_result} end)

    assert {:ok, availability} = ReservationLedger.get_availability(offer.id)
    assert availability.ledger_state == :healthy
    assert availability.available_quantity == 1
    assert availability.reserved_quantity == 1
    assert availability.consumed_quantity == 0

    assert {:ok, %{status: :held, quantity: 1}} =
             ReservationLedger.get_hold_detail(offer.id, "ORD-LATE-2")
  end

  test "successful recovery has no inventory-consume retry stage", %{offer: offer} do
    ctx = LatePaymentRecovery.build_ctx(104, offer.id, "ORD-LATE-4", 1)

    assert {:ok, :paid} = LatePaymentRecovery.recover(ctx, fn -> {:ok, :paid} end)

    assert {:ok, availability} = ReservationLedger.get_availability(offer.id)
    assert availability.ledger_state == :healthy
    assert availability.available_quantity == 1
    assert availability.reserved_quantity == 1
    assert availability.consumed_quantity == 0

    assert {:ok, %{status: :held, quantity: 1}} =
             ReservationLedger.get_hold_detail(offer.id, "ORD-LATE-4")
  end

  test "late-payment retry accepts its exact consumed hold without consuming twice", %{
    offer: offer
  } do
    order_ref = "ORD-LATE-CONSUMED-REPLAY"
    ctx = LatePaymentRecovery.build_ctx(107, offer.id, order_ref, 1)

    assert {:ok, _held} =
             ReservationLedger.reserve(
               offer.id,
               order_ref,
               1,
               ctx.ttl_seconds,
               ctx.reserve_key
             )

    assert {:ok, _consumed} =
             ReservationLedger.consume(offer.id, order_ref, 1, ctx.consume_key)

    assert {:ok, :paid} = LatePaymentRecovery.recover(ctx, fn -> {:ok, :paid} end)

    assert {:ok, %{available_quantity: 1, reserved_quantity: 0, consumed_quantity: 1}} =
             ReservationLedger.get_availability(offer.id)

    assert {:ok, %{status: :consumed, quantity: 1}} =
             ReservationLedger.get_hold_detail(offer.id, order_ref)
  end

  test "successful recovery keeps the reservation for the fulfillment worker", %{
    offer: offer
  } do
    ctx =
      LatePaymentRecovery.build_ctx(103, offer.id, "ORD-LATE-3", 1)

    assert {:ok, :paid} =
             LatePaymentRecovery.recover(ctx, fn -> {:ok, :paid} end)

    assert {:ok, availability} = ReservationLedger.get_availability(offer.id)
    assert availability.available_quantity == 1
    assert availability.reserved_quantity == 1
    assert availability.consumed_quantity == 0
  end
end
