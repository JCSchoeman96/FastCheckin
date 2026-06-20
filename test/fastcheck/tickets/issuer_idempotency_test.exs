defmodule FastCheck.Tickets.IssuerIdempotencyTest do
  use FastCheck.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Sales.Order
  alias FastCheck.Tickets.Issuer

  describe "issue_order/2 TicketIssue idempotency" do
    test "second call returns already_issued without duplicate ticket issues" do
      %{order_id: order_id} = paid_order_fixture(quantity: 2)

      assert {:ok, first} = Issuer.issue_order(order_id)
      assert {:ok, second} = Issuer.issue_order(order_id)

      assert first.status == :ticket_issued
      assert second.status == :already_issued
      assert second.ticket_issue_count == 2
      assert Enum.map(second.ticket_issues, & &1.id) == Enum.map(first.ticket_issues, & &1.id)
      assert ticket_issue_count(order_id) == 2
    end

    test "concurrent calls create exactly one ticket issue per unit" do
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

      assert Enum.all?(results, &match?({:ok, %{ticket_issue_count: 2}}, &1))
      assert ticket_issue_count(order_id) == 2
    end

    test "existing attendees with missing ticket issues get linked on retry" do
      %{order_id: order_id} = paid_order_fixture(quantity: 2)

      assert {:ok, attendee_result} = Issuer.issue_order(order_id)
      assert attendee_result.attendee_count == 2

      delete_ticket_issues_and_backlinks!(order_id)

      assert {:ok, issued_result} = Issuer.issue_order(order_id)
      assert issued_result.status == :ticket_issued
      assert issued_result.ticket_issue_count == 2
      assert ticket_issue_count(order_id) == 2
    end

    test "conflicting ticket issue attendee link moves order to manual_review without overwrite" do
      %{event: event, order_id: order_id, line_id: line_id} = paid_order_fixture(quantity: 1)

      conflicting_attendee =
        create_attendee(event, %{
          ticket_code: "CONFLICTING-ATTENDEE",
          source: "fastcheck_sales",
          source_reference: "sales:#{order_id}:#{line_id}:999",
          sales_order_id: order_id,
          payment_status: "completed",
          scan_eligibility: "active"
        })

      issue_id =
        insert_ticket_issue!(order_id, line_id, 1,
          attendee_id: conflicting_attendee.id,
          ticket_code: conflicting_attendee.ticket_code
        )

      assert {:error, {:manual_review_required, :issuer_ticket_issue_conflict}} =
               Issuer.issue_order(order_id)

      row = ticket_issue_row(issue_id)
      assert row.attendee_id == conflicting_attendee.id
      assert row.ticket_code == conflicting_attendee.ticket_code
      assert Repo.get!(Order, order_id).status == "manual_review"
      assert Repo.get!(Order, order_id).manual_review_reason == "issuer_ticket_issue_conflict"
    end

    test "conflicting attendee ticket issue backlink moves order to manual_review" do
      %{order_id: order_id} = paid_order_fixture(quantity: 1)

      assert {:ok, _} = Issuer.issue_order(order_id)
      [%{attendee_id: attendee_id, id: issue_id}] = ticket_issue_rows(order_id)

      Repo.update_all(
        from(a in Attendee, where: a.id == ^attendee_id),
        set: [sales_ticket_issue_id: issue_id + 10_000]
      )

      assert {:error, {:manual_review_required, :issuer_ticket_issue_conflict}} =
               Issuer.issue_order(order_id)

      assert Repo.get!(Order, order_id).status == "manual_review"
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

  defp insert_ticket_issue!(order_id, line_id, sequence, opts) do
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
        [
          order_id,
          line_id,
          sequence,
          Keyword.fetch!(opts, :attendee_id),
          Keyword.fetch!(opts, :ticket_code)
        ]
      )

    id
  end

  defp ticket_issue_count(order_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id,
        select: count(t.id)
    )
  end

  defp ticket_issue_rows(order_id) do
    Repo.all(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id,
        order_by: t.line_item_sequence,
        select: %{id: t.id, attendee_id: t.attendee_id, ticket_code: t.ticket_code}
    )
  end

  defp ticket_issue_row(issue_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.id == ^issue_id,
        select: %{id: t.id, attendee_id: t.attendee_id, ticket_code: t.ticket_code}
    )
  end

  defp delete_ticket_issues_and_backlinks!(order_id) do
    Repo.update_all(
      from(a in Attendee, where: a.sales_order_id == ^order_id),
      set: [sales_ticket_issue_id: nil]
    )

    Repo.delete_all(from t in "sales_ticket_issues", where: t.sales_order_id == ^order_id)
  end
end
