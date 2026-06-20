defmodule FastCheck.Tickets.IssuerTicketIssueLinkingTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Sales.Order
  alias FastCheck.Tickets.Issuer

  describe "issue_order/2 TicketIssue linking" do
    test "paid verified order creates issued ticket issues and attendee backlinks" do
      %{order_id: order_id, line_id: line_id} = paid_order_fixture(quantity: 3)

      assert {:ok, result} = Issuer.issue_order(order_id)

      assert %{
               order_id: ^order_id,
               status: :ticket_issued,
               attendee_count: 3,
               ticket_issue_count: 3,
               ticket_issues: ticket_issues
             } = result

      assert length(ticket_issues) == 3
      assert Enum.all?(ticket_issues, &Map.has_key?(&1, :id))
      assert Enum.all?(ticket_issues, &Map.has_key?(&1, :attendee_id))
      assert Enum.all?(ticket_issues, &Map.has_key?(&1, :source_reference))

      rows = ticket_issue_rows(order_id)
      assert length(rows) == 3

      assert Enum.map(rows, & &1.line_item_sequence) == [1, 2, 3]

      for row <- rows do
        assert row.sales_order_id == order_id
        assert row.sales_order_line_id == line_id
        assert row.status == "issued"
        assert row.scanner_status == "valid"
        assert row.issued_at
        assert row.ticket_code
        assert row.qr_token_hash
        assert row.delivery_token_hash
        assert row.delivery_token_expires_at
        refute Map.has_key?(row, :qr_token)
        refute Map.has_key?(row, :delivery_token)

        attendee = Repo.get!(Attendee, row.attendee_id)
        assert attendee.sales_ticket_issue_id == row.id
        assert attendee.ticket_code == row.ticket_code
        assert attendee.source == "fastcheck_sales"
        assert attendee.scan_eligibility == "active"
      end

      assert Repo.get!(Order, order_id).status == "ticket_issued"
      assert Repo.get!(Order, order_id).ticket_issued_at

      assert delivery_attempt_count() == 0

      assert ticket_issue_transition_count(order_id) == 3
      assert_ticket_issue_transition_metadata_safe(order_id)
      assert order_transition?(order_id, "ticket_issued")
    end

    test "invalid order state creates no ticket issues" do
      %{order_id: order_id} = paid_order_fixture(order_status: "awaiting_payment")

      assert {:error, {:invalid_order_state, "awaiting_payment"}} = Issuer.issue_order(order_id)

      assert ticket_issue_count(order_id) == 0
    end
  end

  defp paid_order_fixture(opts) do
    event = create_event()
    quantity = Keyword.get(opts, :quantity, 1)
    unit_amount = Keyword.get(opts, :unit_amount_cents, 12_500)
    total = quantity * unit_amount
    order_status = Keyword.get(opts, :order_status, "paid_verified")
    payment_status = Keyword.get(opts, :payment_status, "verified_success")
    checkout_status = Keyword.get(opts, :checkout_status, "paid")

    offer_id = insert_offer!(event.id, unit_amount)
    order_id = insert_order!(event.id, order_status, total)
    line_id = insert_order_line!(order_id, offer_id, quantity, unit_amount, total)
    insert_checkout_session!(order_id, checkout_status, quantity)
    insert_payment_attempt!(order_id, payment_status, total)

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
        [event_id, "Issuer Offer #{System.unique_integer([:positive])}", price_cents]
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

  defp ticket_issue_rows(order_id) do
    Repo.all(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id,
        order_by: t.line_item_sequence,
        select: %{
          id: t.id,
          sales_order_id: t.sales_order_id,
          sales_order_line_id: t.sales_order_line_id,
          line_item_sequence: t.line_item_sequence,
          attendee_id: t.attendee_id,
          ticket_code: t.ticket_code,
          qr_token_hash: t.qr_token_hash,
          delivery_token_hash: t.delivery_token_hash,
          delivery_token_expires_at: t.delivery_token_expires_at,
          status: t.status,
          scanner_status: t.scanner_status,
          issued_at: t.issued_at
        }
    )
  end

  defp ticket_issue_count(order_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id,
        select: count(t.id)
    )
  end

  defp delivery_attempt_count do
    Repo.one!(from d in "sales_delivery_attempts", select: count(d.id))
  end

  defp ticket_issue_transition_count(order_id) do
    Repo.one!(
      from st in "sales_state_transitions",
        join: ti in "sales_ticket_issues",
        on: st.entity_type == "TicketIssue" and st.entity_id == fragment("?::text", ti.id),
        where: ti.sales_order_id == ^order_id and st.to_state == "issued",
        select: count(st.id)
    )
  end

  defp order_transition?(order_id, to_state) do
    Repo.exists?(
      from st in "sales_state_transitions",
        where:
          st.entity_type == "Order" and
            st.entity_id == ^Integer.to_string(order_id) and
            st.to_state == ^to_state
    )
  end

  defp assert_ticket_issue_transition_metadata_safe(order_id) do
    metadata_rows =
      Repo.all(
        from st in "sales_state_transitions",
          join: ti in "sales_ticket_issues",
          on: st.entity_type == "TicketIssue" and st.entity_id == fragment("?::text", ti.id),
          where: ti.sales_order_id == ^order_id and st.to_state == "issued",
          select: st.metadata
      )

    assert length(metadata_rows) == 3

    for metadata <- metadata_rows do
      assert metadata["sales_order_id"]
      assert metadata["sales_order_line_id"]
      assert metadata["line_item_sequence"]
      assert metadata["attendee_id"]
      assert metadata["reason_code"] == "issuer_ticket_issue_linked"

      refute Map.has_key?(metadata, "ticket_code")
      refute Map.has_key?(metadata, "qr_token")
      refute Map.has_key?(metadata, "qr_token_hash")
      refute Map.has_key?(metadata, "delivery_token")
      refute Map.has_key?(metadata, "delivery_token_hash")
      refute Map.has_key?(metadata, "buyer_email")
      refute Map.has_key?(metadata, "buyer_phone")
      refute Map.has_key?(metadata, "raw_payload")
    end
  end
end
