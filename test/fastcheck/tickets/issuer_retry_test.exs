defmodule FastCheck.Tickets.IssuerRetryTest do
  use FastCheck.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Tickets.Issuer

  describe "issue_order/2 duplicate retries" do
    test "sequential duplicate calls create exactly one attendee and ticket issue per unit" do
      %{order_id: order_id} = paid_order_fixture(quantity: 3)

      assert {:ok, first} = Issuer.issue_order(order_id)
      assert {:ok, second} = Issuer.issue_order(order_id)

      assert first.status == :ticket_issued
      assert second.status == :already_issued
      assert first.attendee_count == 3
      assert second.attendee_count == 3
      assert first.ticket_issue_count == 3
      assert second.ticket_issue_count == 3
      assert attendee_count(order_id) == 3
      assert ticket_issue_count(order_id) == 3
    end

    test "concurrent duplicate calls create exactly one attendee and ticket issue per unit" do
      %{order_id: order_id} = paid_order_fixture(quantity: 3)
      parent = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Issuer.issue_order(order_id)
            end
          end)
        end

      for task <- tasks do
        assert_receive {:ready, pid} when pid == task.pid
        Sandbox.allow(Repo, self(), task.pid)
      end

      Enum.each(tasks, fn task -> send(task.pid, :go) end)

      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert Enum.all?(results, &match?({:ok, %{attendee_count: 3, ticket_issue_count: 3}}, &1))
      assert attendee_count(order_id) == 3
      assert ticket_issue_count(order_id) == 3
    end

    test "idempotent retry does not append a duplicate final order transition" do
      %{order_id: order_id} = paid_order_fixture(quantity: 2)

      assert {:ok, %{status: :ticket_issued}} = Issuer.issue_order(order_id)
      assert order_transition_count(order_id, "ticket_issued") == 1

      assert {:ok, %{status: :already_issued}} = Issuer.issue_order(order_id)
      assert order_transition_count(order_id, "ticket_issued") == 1
    end

    test "supplied audit context reaches state transitions without leaking sensitive metadata" do
      %{order_id: order_id} = paid_order_fixture(quantity: 2)
      correlation_id = "corr-vs09d-#{System.unique_integer([:positive])}"
      idempotency_key = "issue-vs09d-#{System.unique_integer([:positive])}"

      assert {:ok, %{status: :ticket_issued}} =
               Issuer.issue_order(order_id,
                 correlation_id: correlation_id,
                 idempotency_key: idempotency_key
               )

      transitions = issuance_transitions(order_id)

      assert length(transitions) == 3
      assert Enum.all?(transitions, &(&1.correlation_id == correlation_id))
      assert Enum.all?(transitions, &(&1.idempotency_key == idempotency_key))

      for transition <- transitions do
        refute Map.has_key?(transition.metadata, "idempotency_key")
        refute Map.has_key?(transition.metadata, "buyer_email")
        refute Map.has_key?(transition.metadata, "buyer_phone")
        refute Map.has_key?(transition.metadata, "ticket_code")
        refute Map.has_key?(transition.metadata, "qr_token")
        refute Map.has_key?(transition.metadata, "qr_token_hash")
        refute Map.has_key?(transition.metadata, "delivery_token")
        refute Map.has_key?(transition.metadata, "delivery_token_hash")
        refute Map.has_key?(transition.metadata, "raw_payload")
      end
    end
  end

  defp paid_order_fixture(opts) do
    event = create_event()
    quantity = Keyword.get(opts, :quantity, 1)
    unit_amount = Keyword.get(opts, :unit_amount_cents, 12_500)
    total = quantity * unit_amount

    offer_id = insert_offer!(event.id, unit_amount)
    order_id = insert_order!(event.id, "paid_verified", total)
    line_id = insert_order_line!(order_id, offer_id, quantity, unit_amount, total)
    insert_checkout_session!(order_id, "paid", quantity)
    insert_payment_attempt!(order_id, "verified_success", total)

    %{event: event, order_id: order_id, line_id: line_id, offer_id: offer_id}
  end

  defp insert_offer!(event_id, price_cents) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'general', $3, 'ZAR', 100, 100, 10, true, 'whatsapp',
           now() - interval '1 day', now() + interval '30 days', 1, now(), now())
        RETURNING id
        """,
        [event_id, "Issuer Retry Offer #{System.unique_integer([:positive])}", price_cents]
      )

    id
  end

  defp insert_order!(event_id, status, total_amount_cents) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, paid_at, lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer Name', '+27123456789', 'buyer@example.com', 'test',
           $3, $4, 'ZAR', now(), 1, now(), now())
        RETURNING id
        """,
        ["ORD-#{System.unique_integer([:positive])}", event_id, status, total_amount_cents]
      )

    id
  end

  defp insert_order_line!(order_id, offer_id, quantity, unit_amount, total_amount) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'General Admission', 'General Admission', 'Issuer Event',
           $3, $4, $5, 'ZAR', '{}', now(), now())
        RETURNING id
        """,
        [order_id, offer_id, quantity, unit_amount, total_amount]
      )

    id
  end

  defp insert_checkout_session!(order_id, status, quantity) do
    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, hold_quantity, state_data, lock_version, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, '{}', 1, now(), now())
      """,
      [order_id, status, quantity]
    )
  end

  defp insert_payment_attempt!(order_id, status, amount_cents) do
    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, status, amount_cents, currency,
         verification_attempt_count, verified_at, last_verified_at, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', $2, $3, $4, 'ZAR', 1, now(), now(), now(), now())
      """,
      [order_id, "PAY-#{System.unique_integer([:positive])}", status, amount_cents]
    )
  end

  defp attendee_count(order_id) do
    Repo.aggregate(
      from(a in Attendee,
        where: a.source == "fastcheck_sales" and a.sales_order_id == ^order_id
      ),
      :count
    )
  end

  defp ticket_issue_count(order_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id,
        select: count(t.id)
    )
  end

  defp order_transition_count(order_id, to_state) do
    Repo.one!(
      from st in "sales_state_transitions",
        where:
          st.entity_type == "Order" and
            st.entity_id == ^Integer.to_string(order_id) and
            st.to_state == ^to_state,
        select: count(st.id)
    )
  end

  defp issuance_transitions(order_id) do
    Repo.all(
      from st in "sales_state_transitions",
        left_join: ti in "sales_ticket_issues",
        on: st.entity_type == "TicketIssue" and st.entity_id == fragment("?::text", ti.id),
        where:
          (st.entity_type == "Order" and st.entity_id == ^Integer.to_string(order_id) and
             st.to_state == "ticket_issued") or
            (st.entity_type == "TicketIssue" and ti.sales_order_id == ^order_id and
               st.to_state == "issued"),
        order_by: [asc: st.id],
        select: %{
          entity_type: st.entity_type,
          to_state: st.to_state,
          correlation_id: st.correlation_id,
          idempotency_key: st.idempotency_key,
          metadata: st.metadata
        }
    )
  end
end
