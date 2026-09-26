defmodule FastCheck.Sales.CheckoutResumabilityTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Inventory.Reconciler
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!()
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "validation failure before reserve leaves checkout rows and inventory unchanged", %{
    offer: offer
  } do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        expected_offer_lock_version: offer.lock_version + 1
      })

    before = availability!(offer.id)

    assert {:error, :offer_changed} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert_zero_checkout_rows!()
    assert availability!(offer.id) == before
  end

  test "malformed required request fields are rejected before inventory reserve", %{
    offer: offer
  } do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        event_name: nil,
        idempotency_key: "saga-invalid-request-#{System.unique_integer([:positive])}"
      })

    before = availability!(offer.id)

    assert {:error, :invalid_checkout_request} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert_zero_checkout_rows!()
    assert availability!(offer.id) == before

    assert {:ok, 0} =
             Redix.command(
               FastCheck.Redix,
               ["EXISTS", "sales:inventory:dedupe:reserve:#{input.idempotency_key}"]
             )
  end

  test "same idempotency key retries after stock returns and replays after a lost response", %{
    offer: offer
  } do
    :ok = ReservationLedger.initialize_offer(offer.id, 0)
    before = availability!(offer.id)

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "saga-retry-#{System.unique_integer([:positive])}"
      })

    assert {:error, :insufficient_inventory} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert_zero_checkout_rows!()
    assert availability!(offer.id) == before

    :ok = ReservationLedger.initialize_offer(offer.id, 100)

    assert {:ok, first} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    after_commit = availability!(offer.id)
    assert first.order.status == "awaiting_payment"
    assert first.checkout_session.status == "hold_attached"

    # Simulate a caller that lost the response after commit and retries the request.
    assert {:ok, replay} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert replay.order.id == first.order.id
    assert replay.checkout_session.id == first.checkout_session.id
    assert availability!(offer.id) == after_commit
    assert_checkout_row_counts!(1)
  end

  test "concurrent duplicate checkouts create one commercial checkout", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "saga-concurrent-#{System.unique_integer([:positive])}"
      })

    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          Checkout.start_checkout(input, Fixtures.system_actor(),
            effective_sales_channel: "whatsapp"
          )
        end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    successful_orders =
      for {:ok, %{order: order}} <- results, do: order.id

    assert successful_orders != []
    assert length(Enum.uniq(successful_orders)) == 1
    assert_checkout_row_counts!(1)

    assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
    assert snapshot.reserved_quantity == 1
  end

  test "database failure after reserve rolls back rows and releases the hold", %{offer: offer} do
    install_hold_update_failure!()

    try do
      input =
        Fixtures.checkout_input(%{
          ticket_offer_id: offer.id,
          idempotency_key: "saga-db-failure-#{System.unique_integer([:positive])}"
        })

      task =
        Task.async(fn ->
          Checkout.start_checkout(input, Fixtures.system_actor(),
            effective_sales_channel: "whatsapp"
          )
        end)

      order_reference = await_single_hold!(offer.id)
      assert {:error, _reason} = Task.await(task, 10_000)

      assert_zero_checkout_rows!()

      assert {:ok, %{status: :released}} =
               ReservationLedger.get_hold_detail(offer.id, order_reference)

      assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
      assert snapshot.available_quantity == 100
      assert snapshot.reserved_quantity == 0

      release_key = compensation_release_key(order_reference)

      assert {:ok, %{idempotent: true}} =
               ReservationLedger.release(offer.id, order_reference, release_key)
    after
      remove_hold_update_failure!()
    end
  end

  test "failed compensation leaves a bounded orphan hold and emits reconciliation signal", %{
    offer: offer
  } do
    install_hold_update_failure!()

    handler_id = "checkout-resumability-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:fastcheck, :sales, :inventory, :manual_review_required],
        fn _event, _measurements, metadata, parent ->
          send(parent, {:inventory_reconciliation_required, metadata})
        end,
        self()
      )

    try do
      input =
        Fixtures.checkout_input(%{
          ticket_offer_id: offer.id,
          buyer_name: "Secret Buyer",
          buyer_email: "private@example.com",
          idempotency_key: "saga-release-failure-#{System.unique_integer([:positive])}"
        })

      task =
        Task.async(fn ->
          Checkout.start_checkout(input, Fixtures.system_actor(),
            effective_sales_channel: "whatsapp"
          )
        end)

      order_reference = await_single_hold!(offer.id)
      lock_key = "sales:order:#{order_reference}:lock"
      assert {:ok, "OK"} = Redix.command(FastCheck.Redix, ["SET", lock_key, "test", "PX", "5000"])

      try do
        assert {:error, :inventory_unavailable} = Task.await(task, 10_000)
      after
        Redix.command(FastCheck.Redix, ["DEL", lock_key])
      end

      assert_zero_checkout_rows!()

      assert_receive {:inventory_reconciliation_required, metadata}, 1_000
      assert metadata.offer_id == offer.id
      assert metadata.public_reference == order_reference
      refute Map.has_key?(metadata, :buyer_name)
      refute Map.has_key?(metadata, :buyer_phone)
      refute Map.has_key?(metadata, :buyer_email)

      assert {:ok, %{status: :held, expires_at: expires_at}} =
               ReservationLedger.get_hold_detail(offer.id, order_reference)

      assert expires_at > System.system_time(:millisecond)
      assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
      assert snapshot.available_quantity == 99
      assert snapshot.reserved_quantity == 1
      assert snapshot.ledger_state == :reconciliation_required

      assert {:manual_review_required, report} =
               Reconciler.reconcile_offer(offer.id, dry_run: true)

      assert report.orphan_hold_count == 1
      assert report.manual_review_required?
    after
      :telemetry.detach(handler_id)
      remove_hold_update_failure!()
    end
  end

  defp availability!(offer_id) do
    assert {:ok, snapshot} = ReservationLedger.get_availability(offer_id)
    snapshot
  end

  defp assert_zero_checkout_rows! do
    assert_checkout_row_counts!(0)
    assert Repo.aggregate("oban_jobs", :count, :id) == 0
  end

  defp assert_checkout_row_counts!(count) do
    assert Repo.aggregate("sales_orders", :count, :id) == count
    assert Repo.aggregate("sales_order_lines", :count, :id) == count
    assert Repo.aggregate("sales_checkout_sessions", :count, :id) == count
    assert Repo.aggregate("sales_payment_attempts", :count, :id) == 0
  end

  defp await_single_hold!(offer_id, deadline_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_single_hold(offer_id, deadline)
  end

  defp do_await_single_hold(offer_id, deadline) do
    case ReservationLedger.list_hold_refs(offer_id) do
      {:ok, [order_reference]} ->
        order_reference

      {:ok, []} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_await_single_hold(offer_id, deadline)
        else
          flunk("expected a reserved hold before deadline, got none")
        end

      result ->
        flunk("expected one reserved hold before deadline, got: #{inspect(result)}")
    end
  end

  defp install_hold_update_failure! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION p0_a_fail_checkout_hold_update() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_sleep(1);
      RAISE EXCEPTION 'forced checkout database failure';
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER p0_a_fail_checkout_hold_update
    BEFORE UPDATE ON sales_checkout_sessions
    FOR EACH ROW
    WHEN (NEW.status = 'hold_attached')
    EXECUTE FUNCTION p0_a_fail_checkout_hold_update()
    """)
  end

  defp remove_hold_update_failure! do
    Repo.query!(
      "DROP TRIGGER IF EXISTS p0_a_fail_checkout_hold_update ON sales_checkout_sessions"
    )

    Repo.query!("DROP FUNCTION IF EXISTS p0_a_fail_checkout_hold_update()")
  end

  defp compensation_release_key(order_reference),
    do: "checkout-compensate-release-#{order_reference}"
end
