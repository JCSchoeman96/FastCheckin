defmodule FastCheck.Tickets.IssuerAttendeeBridgeTest do
  use FastCheck.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Tickets.Issuer

  describe "issue_order/2 attendee bridge" do
    test "paid verified order with quantity 3 creates scanner-compatible attendees" do
      %{event: event, order_id: order_id, line_id: line_id} = paid_order_fixture(quantity: 3)

      assert {:ok, result} = Issuer.issue_order(order_id)

      assert %{
               order_id: ^order_id,
               status: :attendees_ready,
               attendee_count: 3,
               attendees: attendees
             } = result

      refute result.status == :ticket_issued
      assert length(attendees) == 3

      source_refs = Enum.map(attendees, & &1.source_reference)

      assert source_refs == [
               "sales:#{order_id}:#{line_id}:1",
               "sales:#{order_id}:#{line_id}:2",
               "sales:#{order_id}:#{line_id}:3"
             ]

      rows =
        Repo.all(
          from a in Attendee,
            where: a.source == "fastcheck_sales" and a.sales_order_id == ^order_id,
            order_by: a.source_reference
        )

      assert length(rows) == 3

      for attendee <- rows do
        assert attendee.event_id == event.id
        assert attendee.source == "fastcheck_sales"
        assert attendee.sales_ticket_issue_id == nil
        assert attendee.payment_status == "completed"
        assert attendee.scan_eligibility == "active"
        assert attendee.allowed_checkins == 1
        assert attendee.checkins_remaining == 1
        assert attendee.ticket_type == "General Admission"
        assert String.starts_with?(attendee.ticket_code, "FC-")
      end

      assert sales_ticket_issue_count() == 0
    end

    test "second issue_order call reuses the same attendees" do
      %{order_id: order_id} = paid_order_fixture(quantity: 2)

      assert {:ok, first} = Issuer.issue_order(order_id)
      assert {:ok, second} = Issuer.issue_order(order_id)

      assert first.status == :attendees_ready
      assert second.status == :attendees_already_ready
      assert second.attendee_count == 2
      assert Enum.map(second.attendees, & &1.id) == Enum.map(first.attendees, & &1.id)

      assert Repo.aggregate(
               from(a in Attendee,
                 where: a.source == "fastcheck_sales" and a.sales_order_id == ^order_id
               ),
               :count
             ) == 2
    end

    test "concurrent issue_order calls do not duplicate attendees" do
      %{order_id: order_id} = paid_order_fixture(quantity: 2)
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

      assert Enum.all?(results, &match?({:ok, %{attendee_count: 2}}, &1))

      assert Repo.aggregate(
               from(a in Attendee,
                 where: a.source == "fastcheck_sales" and a.sales_order_id == ^order_id
               ),
               :count
             ) == 2
    end

    test "invalid order state creates no attendees" do
      %{order_id: order_id} = paid_order_fixture(order_status: "awaiting_payment")

      assert {:error, {:invalid_order_state, "awaiting_payment"}} = Issuer.issue_order(order_id)

      assert Repo.aggregate(
               from(a in Attendee,
                 where: a.source == "fastcheck_sales" and a.sales_order_id == ^order_id
               ),
               :count
             ) == 0
    end

    test "order without verified successful payment creates no attendees" do
      %{order_id: order_id} = paid_order_fixture(payment_status: "failed")

      assert {:error, {:invalid_payment_state, :missing_verified_success}} =
               Issuer.issue_order(order_id)

      assert Repo.aggregate(
               from(a in Attendee,
                 where: a.source == "fastcheck_sales" and a.sales_order_id == ^order_id
               ),
               :count
             ) == 0
    end

    test "order without paid checkout session creates no attendees" do
      %{order_id: order_id} = paid_order_fixture(checkout_status: "payment_link_sent")

      assert {:error, {:invalid_checkout_state, "payment_link_sent"}} =
               Issuer.issue_order(order_id)

      assert Repo.aggregate(
               from(a in Attendee,
                 where: a.source == "fastcheck_sales" and a.sales_order_id == ^order_id
               ),
               :count
             ) == 0
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

  defp sales_ticket_issue_count do
    Repo.one!(from t in "sales_ticket_issues", select: count(t.id))
  end
end
