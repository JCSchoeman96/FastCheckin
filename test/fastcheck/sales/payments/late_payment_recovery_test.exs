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
      Application.delete_env(:fastcheck, :late_payment_recovery_consume_fun)
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

  test "marks reconciliation and keeps paid result when consume fails after paid transition", %{
    offer: offer
  } do
    ctx =
      LatePaymentRecovery.build_ctx(102, offer.id, "ORD-LATE-2", 1)

    paid_result = %{order_id: 55, session_id: 66}

    Application.put_env(
      :fastcheck,
      :late_payment_recovery_consume_fun,
      fn _ctx ->
        {:error, :hold_not_found, %{offer_id: offer.id}}
      end
    )

    assert {:error, :paid_reconciliation_required, reason, ^paid_result} =
             LatePaymentRecovery.recover(ctx, fn -> {:ok, paid_result} end)

    assert reason == PaymentFailureReason.late_payment_inventory_ledger_unhealthy()

    assert {:ok, availability} = ReservationLedger.get_availability(offer.id)
    assert availability.ledger_state == :reconciliation_required
  end

  test "successful recovery consumes inventory without leaving unpaid order state", %{
    offer: offer
  } do
    ctx =
      LatePaymentRecovery.build_ctx(103, offer.id, "ORD-LATE-3", 1)

    assert {:ok, :paid} =
             LatePaymentRecovery.recover(ctx, fn -> {:ok, :paid} end)

    assert {:ok, availability} = ReservationLedger.get_availability(offer.id)
    assert availability.available_quantity == 1
    assert availability.consumed_quantity == 1
  end
end
