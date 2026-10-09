defmodule FastCheck.Sales.CheckoutCancellationTest do
  use FastCheck.DataCase, async: false

  alias Ash.Changeset
  alias Ash.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.CheckoutExpiry
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.Sales.Payments.TransactionInitialization
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    paystack_cleanup = TestSupport.setup_paystack!()
    offer = Fixtures.insert_offer!()
    conversation_id = insert_conversation!()

    on_exit(fn ->
      Fixtures.flush_inventory_keys(offer.id)
      Application.delete_env(:fastcheck, :checkout_expiry_release_fun)
      paystack_cleanup.()
    end)

    {:ok, offer: offer, conversation_id: conversation_id}
  end

  test "cancels a held unpaid order and its session", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order, session: session} = held_checkout!(offer, conversation_id)
    assert {:ok, before} = ReservationLedger.get_availability(offer.id)
    assert before.reserved_quantity == 1

    assert {:ok, :cancelled} = CheckoutExpiry.cancel_order(order.id, conversation_id)

    assert reload_order!(order.id).status == "cancelled"
    assert reload_session!(session.id).status == "cancelled"
    assert {:ok, after_snapshot} = ReservationLedger.get_availability(offer.id)
    assert after_snapshot.reserved_quantity == 0
  end

  test "cancels a draft with no hold without calling the ledger", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order, session: session} = draft_checkout!(offer, conversation_id)
    parent = self()

    Application.put_env(
      :fastcheck,
      :checkout_expiry_release_fun,
      fn _offer_id, _public_reference, _key ->
        send(parent, :unexpected_release)
        {:ok, %{status: :released}}
      end
    )

    assert {:ok, :cancelled} = CheckoutExpiry.cancel_order(order.id, conversation_id)
    refute_receive :unexpected_release
    assert reload_order!(order.id).status == "cancelled"
    assert reload_session!(session.id).status == "cancelled"
  end

  test "a repeated cancellation is idempotent and releases once", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order} = held_checkout!(offer, conversation_id)
    parent = self()

    Application.put_env(
      :fastcheck,
      :checkout_expiry_release_fun,
      fn _offer_id, _public_reference, key ->
        send(parent, {:released, key})
        {:ok, %{status: :released}}
      end
    )

    assert {:ok, :cancelled} = CheckoutExpiry.cancel_order(order.id, conversation_id)
    assert_receive {:released, "checkout_expiry:release:" <> _session_id}
    assert {:ok, :already_cancelled} = CheckoutExpiry.cancel_order(order.id, conversation_id)
    refute_receive {:released, _}
  end

  test "a ledger outage leaves the order cancellable for retry", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order, session: session} = held_checkout!(offer, conversation_id)

    Application.put_env(
      :fastcheck,
      :checkout_expiry_release_fun,
      fn _offer_id, _public_reference, _key ->
        {:error, :ledger_unavailable, %{reason: "test"}}
      end
    )

    assert {:error, :ledger_unavailable} = CheckoutExpiry.cancel_order(order.id, conversation_id)
    assert reload_order!(order.id).status == "awaiting_payment"
    assert reload_session!(session.id).status == "hold_attached"

    Application.put_env(
      :fastcheck,
      :checkout_expiry_release_fun,
      fn _offer_id, _public_reference, _key -> {:ok, %{status: :released}} end
    )

    assert {:ok, :cancelled} = CheckoutExpiry.cancel_order(order.id, conversation_id)
  end

  test "a conversation that does not own the order cannot cancel it", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order} = held_checkout!(offer, conversation_id)
    other_conversation_id = insert_conversation!()
    parent = self()

    Application.put_env(
      :fastcheck,
      :checkout_expiry_release_fun,
      fn _offer_id, _public_reference, _key ->
        send(parent, :unexpected_release)
        {:ok, %{status: :released}}
      end
    )

    assert {:error, :conversation_mismatch} =
             CheckoutExpiry.cancel_order(order.id, other_conversation_id)

    refute_receive :unexpected_release
    assert reload_order!(order.id).status == "awaiting_payment"
  end

  test "verified and unresolved payment attempts block cancellation", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    for status <- ["initialized", "initializing", "verification_started", "verified_success"] do
      %{order: order} = held_checkout!(offer, conversation_id)
      insert_payment_attempt!(order.id, status)

      assert {:error, reason} = CheckoutExpiry.cancel_order(order.id, conversation_id)
      assert reason in [:payment_attempt_unresolved, :payment_verified]
      assert reload_order!(order.id).status == "awaiting_payment"
    end
  end

  test "any payment attempt blocks cancellation, including failed attempts", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order} = held_checkout!(offer, conversation_id)
    insert_payment_attempt!(order.id, "failed")

    assert {:error, :payment_attempt_unresolved} =
             CheckoutExpiry.cancel_order(order.id, conversation_id)
  end

  test "the menu hint hides cancellation when an attempt exists", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order} = held_checkout!(offer, conversation_id)

    assert CheckoutExpiry.customer_cancellation_available?(order)

    insert_payment_attempt!(order.id, "failed")
    refute CheckoutExpiry.customer_cancellation_available?(reload_order!(order.id))
  end

  test "ticket issues and attendees block cancellation", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order, line_id: line_id} = held_checkout_with_line!(offer, conversation_id)
    insert_ticket_issue!(order.id, line_id)

    assert {:error, :ticket_issue_exists} = CheckoutExpiry.cancel_order(order.id, conversation_id)

    %{order: attendee_order} = held_checkout!(offer, conversation_id)

    Repo.query!(
      """
      INSERT INTO attendees
        (event_id, ticket_code, source, sales_order_id, inserted_at, updated_at)
      VALUES ($1, $2, 'fastcheck_sales', $3, now(), now())
      """,
      [offer.event_id, "ATT-#{attendee_order.id}", attendee_order.id]
    )

    assert {:error, :attendee_exists} =
             CheckoutExpiry.cancel_order(attendee_order.id, conversation_id)
  end

  test "protected order states cannot be cancelled", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    for status <- [
          "paid_unverified",
          "paid_verified",
          "fulfillment_queued",
          "ticket_issued",
          "partially_issued",
          "issuance_retry_queued",
          "manual_review",
          "manual_review_held",
          "no_fulfillment_closed",
          "refunded",
          "expired"
        ] do
      %{order: order} = held_checkout!(offer, conversation_id)
      Repo.update_all(from(o in "sales_orders", where: o.id == ^order.id), set: [status: status])

      assert {:error, :order_not_cancellable} =
               CheckoutExpiry.cancel_order(order.id, conversation_id)
    end
  end

  test "hold anomalies fail closed without cancelling", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order} = held_checkout!(offer, conversation_id)

    Repo.update_all(
      from(cs in "sales_checkout_sessions", where: cs.sales_order_id == ^order.id),
      set: [redis_hold_key: nil]
    )

    assert {:error, :hold_state_anomaly} = CheckoutExpiry.cancel_order(order.id, conversation_id)
    assert reload_order!(order.id).status == "awaiting_payment"
  end

  test "verification releases the order lock before provider HTTP", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order, session: session, attempt: attempt} =
      TestSupport.initialized_payment!(offer, sales_conversation_id: conversation_id)

    parent = self()

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      barrier_verify_request_fun(parent, provider_status: "success", amount: attempt.amount_cents)
    )

    verification_task =
      Task.async(fn -> PaymentVerification.verify_attempt(attempt.id) end)

    Sandbox.allow(Repo, self(), verification_task.pid)
    assert_receive :verification_http_started, 5_000

    cancellation_task =
      Task.async(fn -> CheckoutExpiry.cancel_order(order.id, order.sales_conversation_id) end)

    Sandbox.allow(Repo, self(), cancellation_task.pid)
    assert {:error, :payment_attempt_unresolved} = Task.await(cancellation_task, 5_000)
    assert reload_order!(order.id).status == "awaiting_payment"
    assert reload_attempt!(attempt.id).status == "verification_started"

    send(verification_task.pid, :release_verification_http)
    assert {:ok, :verified} = Task.await(verification_task, 5_000)
    assert reload_order!(order.id).status == "paid_verified"
    assert reload_session!(session.id).status == "paid"
    assert reload_attempt!(attempt.id).status == "verified_success"
  end

  test "initialization reloads cancellation after waiting for the order lock", %{
    offer: offer,
    conversation_id: conversation_id
  } do
    %{order: order, session: session} = held_checkout!(offer, conversation_id)

    {request_fun, request_counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:ok, :cancelled} = CheckoutExpiry.cancel_order(order.id, conversation_id)

    assert {:error, %{type: :invalid_order_state}} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert reload_order!(order.id).status == "cancelled"
    assert reload_session!(session.id).status == "cancelled"

    assert Repo.aggregate(
             from(pa in "sales_payment_attempts", where: pa.sales_order_id == ^order.id),
             :count,
             :id
           ) == 0

    assert :counters.get(request_counter, 1) == 0
  end

  defp held_checkout!(offer, conversation_id) do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        source_channel: "whatsapp",
        sales_conversation_id: conversation_id,
        idempotency_key: "cancel-#{System.unique_integer([:positive])}"
      })

    {:ok, %{order: order, checkout_session: session}} =
      Checkout.start_checkout(input, Fixtures.system_actor([offer.event_id]),
        effective_sales_channel: "whatsapp"
      )

    %{order: reload_order!(order.id), session: reload_session!(session.id)}
  end

  defp held_checkout_with_line!(offer, conversation_id) do
    %{order: order, session: session} = held_checkout!(offer, conversation_id)

    [[line_id]] =
      Repo.query!(
        "SELECT id FROM sales_order_lines WHERE sales_order_id = $1 LIMIT 1",
        [order.id]
      ).rows

    %{order: order, session: session, line_id: line_id}
  end

  defp draft_checkout!(offer, conversation_id) do
    actor = Fixtures.system_actor([offer.event_id])

    order =
      Order
      |> Changeset.for_create(
        :create_draft,
        %{
          public_reference: "FC-CANCEL-DRAFT-#{System.unique_integer([:positive])}",
          event_id: offer.event_id,
          buyer_phone: "+27123456789",
          source_channel: "whatsapp",
          total_amount_cents: offer.price_cents,
          currency: offer.currency,
          idempotency_key: "cancel-draft-#{System.unique_integer([:positive])}",
          sales_conversation_id: conversation_id
        },
        actor: actor
      )
      |> Ash.create!(authorize?: false)

    session =
      CheckoutSession
      |> Changeset.for_create(:create_session, %{sales_order_id: order.id}, actor: actor)
      |> Ash.create!(authorize?: false)

    %{order: order, session: session}
  end

  defp insert_payment_attempt!(order_id, status) do
    provider_reference = "FC-CANCEL-ATTEMPT-#{System.unique_integer([:positive])}"

    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, status,
         amount_cents, currency, verification_attempt_count, inserted_at, updated_at)
      SELECT id, 'paystack', $2, $3, $4, total_amount_cents, currency, 0, now(), now()
      FROM sales_orders
      WHERE id = $1
      RETURNING id
      """,
      [
        order_id,
        provider_reference,
        "cancel-attempt-#{System.unique_integer([:positive])}",
        status
      ]
    ).rows
    |> List.first()
    |> List.first()
    |> then(&reload_attempt!(&1))
  end

  defp insert_ticket_issue!(order_id, line_id) do
    Repo.query!(
      """
      INSERT INTO sales_ticket_issues
        (sales_order_id, sales_order_line_id, line_item_sequence, status,
         inserted_at, updated_at)
      VALUES ($1, $2, 1, 'pending', now(), now())
      """,
      [order_id, line_id]
    )
  end

  defp insert_conversation! do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human,
           inserted_at, updated_at)
        VALUES ($1, $2, 'en', 'main_menu', '{}', false, now(), now())
        RETURNING id
        """,
        ["+27123456789", "cancel-#{System.unique_integer([:positive])}"]
      )

    id
  end

  defp barrier_verify_request_fun(parent, opts) do
    verify_fun = TestSupport.verify_success_request_fun(opts)

    fn req ->
      path = URI.parse(to_string(req.url)).path || ""

      if String.contains?(path, "/transaction/verify/") do
        send(parent, :verification_http_started)

        receive do
          :release_verification_http -> verify_fun.(req)
        after
          5_000 -> {:error, %Req.TransportError{reason: :timeout}}
        end
      else
        TestSupport.success_request_fun().(req)
      end
    end
  end

  defp reload_order!(id) do
    Order
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_session!(id) do
    CheckoutSession
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_attempt!(id) do
    FastCheck.Sales.PaymentAttempt
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end
end
