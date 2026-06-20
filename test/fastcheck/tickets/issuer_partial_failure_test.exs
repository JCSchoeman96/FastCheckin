defmodule FastCheck.Tickets.IssuerPartialFailureTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Sales.Order
  alias FastCheck.Tickets.Issuer

  describe "issue_order/2 durable partial state recovery" do
    test "reuses existing attendees and creates missing ticket issues only" do
      %{event: event, order_id: order_id, line_id: line_id} = paid_order_fixture(quantity: 2)
      attendee_1 = insert_sales_attendee!(event, order_id, line_id, 1)
      attendee_2 = insert_sales_attendee!(event, order_id, line_id, 2)

      assert {:ok, result} = Issuer.issue_order(order_id)

      assert result.status == :ticket_issued
      assert result.attendee_count == 2
      assert result.ticket_issue_count == 2
      assert attendee_count(order_id) == 2
      assert ticket_issue_count(order_id) == 2
      assert_attendee_backlinked(attendee_1.id)
      assert_attendee_backlinked(attendee_2.id)
    end

    test "reuses an existing ticket issue and completes missing later units only" do
      %{event: event, order_id: order_id, line_id: line_id} = paid_order_fixture(quantity: 2)
      attendee_1 = insert_sales_attendee!(event, order_id, line_id, 1)
      attendee_2 = insert_sales_attendee!(event, order_id, line_id, 2)
      existing_issue_id = insert_ticket_issue!(order_id, line_id, 1, attendee_1)
      backlink_attendee!(attendee_1.id, existing_issue_id)

      assert {:ok, result} = Issuer.issue_order(order_id)

      assert result.status == :ticket_issued
      assert result.ticket_issue_count == 2
      assert ticket_issue_count(order_id) == 2
      assert Enum.any?(result.ticket_issues, &(&1.id == existing_issue_id))
      assert_attendee_backlinked(attendee_2.id)
    end

    test "finalizes order when all attendees and ticket issues already exist" do
      %{event: event, order_id: order_id, line_id: line_id} = paid_order_fixture(quantity: 2)

      for sequence <- 1..2 do
        attendee = insert_sales_attendee!(event, order_id, line_id, sequence)
        issue_id = insert_ticket_issue!(order_id, line_id, sequence, attendee)
        backlink_attendee!(attendee.id, issue_id)
      end

      assert Repo.get!(Order, order_id).status == "paid_verified"
      assert ticket_issue_count(order_id) == 2

      assert {:ok, result} = Issuer.issue_order(order_id)

      assert result.status == :ticket_issued
      assert Repo.get!(Order, order_id).status == "ticket_issued"
      assert ticket_issue_count(order_id) == 2
      assert order_transition_count(order_id, "ticket_issued") == 1
    end

    test "conflicting attendee scanner state moves order to manual_review without overwrite" do
      %{event: event, order_id: order_id, line_id: line_id} = paid_order_fixture(quantity: 1)

      attendee =
        insert_sales_attendee!(event, order_id, line_id, 1, %{
          scan_eligibility: "not_scannable",
          ineligibility_reason: "fixture_conflict"
        })

      assert {:error, {:manual_review_required, :issuer_attendee_conflict}} =
               Issuer.issue_order(order_id)

      reloaded = Repo.get!(Attendee, attendee.id)
      assert reloaded.scan_eligibility == "not_scannable"
      assert reloaded.ineligibility_reason == "fixture_conflict"
      assert ticket_issue_count(order_id) == 0
      assert Repo.get!(Order, order_id).status == "manual_review"
      assert Repo.get!(Order, order_id).manual_review_reason == "issuer_attendee_conflict"
    end

    test "conflicting ticket issue row moves order to manual_review without overwrite" do
      %{event: event, order_id: order_id, line_id: line_id} = paid_order_fixture(quantity: 1)
      _expected_attendee = insert_sales_attendee!(event, order_id, line_id, 1)

      conflicting_attendee =
        create_attendee(event, %{
          ticket_code: "CONFLICT-#{System.unique_integer([:positive])}",
          source: "fastcheck_sales",
          source_reference: "sales:#{order_id}:#{line_id}:999",
          sales_order_id: order_id,
          payment_status: "completed",
          scan_eligibility: "active"
        })

      issue_id = insert_ticket_issue!(order_id, line_id, 1, conflicting_attendee)
      correlation_id = "corr-manual-#{System.unique_integer([:positive])}"
      idempotency_key = "idem-manual-#{System.unique_integer([:positive])}"

      assert {:error, {:manual_review_required, :issuer_ticket_issue_conflict}} =
               Issuer.issue_order(order_id,
                 correlation_id: correlation_id,
                 idempotency_key: idempotency_key
               )

      issue = ticket_issue_row(issue_id)
      assert issue.attendee_id == conflicting_attendee.id
      assert issue.ticket_code == conflicting_attendee.ticket_code
      assert ticket_issue_count(order_id) == 1
      assert Repo.get!(Order, order_id).status == "manual_review"
      assert Repo.get!(Order, order_id).manual_review_reason == "issuer_ticket_issue_conflict"

      transition = order_transition!(order_id, "manual_review")
      assert transition.correlation_id == correlation_id
      assert transition.idempotency_key == idempotency_key
    end

    test "issuer recovery does not create delivery attempts" do
      %{event: event, order_id: order_id, line_id: line_id} = paid_order_fixture(quantity: 2)
      attendee = insert_sales_attendee!(event, order_id, line_id, 1)
      issue_id = insert_ticket_issue!(order_id, line_id, 1, attendee)
      backlink_attendee!(attendee.id, issue_id)

      assert {:ok, %{status: :ticket_issued}} = Issuer.issue_order(order_id)

      assert delivery_attempt_count() == 0
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

  defp insert_sales_attendee!(event, order_id, line_id, sequence, attrs \\ %{}) do
    create_attendee(
      event,
      Map.merge(
        %{
          ticket_code: "SALES-#{order_id}-#{line_id}-#{sequence}",
          source: "fastcheck_sales",
          source_reference: "sales:#{order_id}:#{line_id}:#{sequence}",
          sales_order_id: order_id,
          payment_status: "completed",
          scan_eligibility: "active",
          allowed_checkins: 1,
          checkins_remaining: 1
        },
        attrs
      )
    )
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
        [event_id, "Issuer Partial Offer #{System.unique_integer([:positive])}", price_cents]
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

  defp insert_ticket_issue!(order_id, line_id, sequence, attendee) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_issues
          (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
           status, scanner_status, inserted_at, updated_at)
        VALUES
          ($1, $2, $3, $4, $5, 'issued', 'valid', now(), now())
        RETURNING id
        """,
        [order_id, line_id, sequence, attendee.id, attendee.ticket_code]
      )

    id
  end

  defp backlink_attendee!(attendee_id, issue_id) do
    Repo.update_all(
      from(a in Attendee, where: a.id == ^attendee_id),
      set: [sales_ticket_issue_id: issue_id]
    )
  end

  defp assert_attendee_backlinked(attendee_id) do
    attendee = Repo.get!(Attendee, attendee_id)
    assert attendee.sales_ticket_issue_id
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

  defp ticket_issue_row(issue_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.id == ^issue_id,
        select: %{id: t.id, attendee_id: t.attendee_id, ticket_code: t.ticket_code}
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

  defp order_transition!(order_id, to_state) do
    Repo.one!(
      from st in "sales_state_transitions",
        where:
          st.entity_type == "Order" and
            st.entity_id == ^Integer.to_string(order_id) and
            st.to_state == ^to_state,
        select: %{correlation_id: st.correlation_id, idempotency_key: st.idempotency_key}
    )
  end

  defp delivery_attempt_count do
    Repo.one!(from d in "sales_delivery_attempts", select: count(d.id))
  end
end
