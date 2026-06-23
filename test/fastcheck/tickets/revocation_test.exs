defmodule FastCheck.Tickets.RevocationTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.AttendeeInvalidationEvent
  alias FastCheck.Attendees.ReasonCodes
  alias FastCheck.Attendees.Scan
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Scans.HotState.DbAuthority
  alias FastCheck.Tickets.Issuer
  alias FastCheck.Tickets.Revocation

  describe "revoke_ticket_issue/2" do
    test "revokes issued ticket issue and marks attendee not_scannable" do
      %{order_id: order_id, event: event} = issued_order_fixture()

      ticket_issue_id = first_ticket_issue_id(order_id)
      version_before = event_sync_version(event.id)

      assert {:ok,
              %{status: :revoked, ticket_issue_id: ^ticket_issue_id, attendee_id: attendee_id}} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :system,
                 actor_id: "test",
                 correlation_id: "corr-1",
                 reason: "manual_review"
               )

      row = ticket_issue_row(ticket_issue_id)
      assert row.status == "revoked"
      assert row.revoked_at
      assert row.revocation_reason == "manual_review"
      assert row.scanner_status == "revoked"
      assert row.delivery_token_expires_at

      attendee = Repo.get!(Attendee, attendee_id)
      assert attendee.scan_eligibility == "not_scannable"
      assert attendee.ineligibility_reason == ReasonCodes.revoked()

      assert Repo.aggregate(
               from(i in AttendeeInvalidationEvent, where: i.attendee_id == ^attendee_id),
               :count
             ) == 1

      assert event_sync_version(event.id) == version_before + 1
      assert revoke_transition_count(ticket_issue_id) == 1
    end

    test "duplicate revoke is idempotent without duplicate transitions or invalidations" do
      %{order_id: order_id} = issued_order_fixture()
      ticket_issue_id = first_ticket_issue_id(order_id)
      opts = [actor_type: :system, actor_id: "test", correlation_id: "corr-dup", reason: "refund"]

      assert {:ok, %{status: :revoked}} = Revocation.revoke_ticket_issue(ticket_issue_id, opts)

      attendee_id = ticket_issue_row(ticket_issue_id).attendee_id
      invalidation_count_before = invalidation_count(attendee_id)
      transition_count_before = revoke_transition_count(ticket_issue_id)
      version_before = event_sync_version_for_ticket_issue(ticket_issue_id)

      assert {:ok, %{status: :already_revoked}} =
               Revocation.revoke_ticket_issue(ticket_issue_id, opts)

      assert invalidation_count(attendee_id) == invalidation_count_before
      assert revoke_transition_count(ticket_issue_id) == transition_count_before
      assert event_sync_version_for_ticket_issue(ticket_issue_id) == version_before
    end

    test "scanner check_in rejects revoked attendee" do
      %{order_id: order_id, event: event} = issued_order_fixture()
      ticket_issue_id = first_ticket_issue_id(order_id)
      ticket_code = ticket_issue_row(ticket_issue_id).ticket_code

      assert {:ok, %{status: :revoked}} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :system,
                 actor_id: "test",
                 correlation_id: "corr-scan",
                 reason: "cancel"
               )

      assert {:error, "TICKET_NOT_SCANNABLE", _} =
               Scan.check_in(event.id, ticket_code, "Main", "Op")
    end

    test "DbAuthority rejects revoked attendee" do
      %{order_id: order_id, event: event} = issued_order_fixture()
      ticket_issue_id = first_ticket_issue_id(order_id)
      row = ticket_issue_row(ticket_issue_id)

      assert {:ok, %{status: :revoked}} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :system,
                 actor_id: "test",
                 correlation_id: "corr-db",
                 reason: "cancel"
               )

      assert {:reject, {:not_scannable, _}} = DbAuthority.check(event.id, row.ticket_code)
    end

    test "customer_session actor cannot revoke" do
      ticket_issue_id = first_ticket_issue_id(issued_order_fixture().order_id)

      assert {:error, :forbidden} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :customer_session,
                 actor_id: "cust",
                 reason: "nope"
               )
    end

    test "admin actor requires reason" do
      %{order_id: order_id, event: event} = issued_order_fixture()
      ticket_issue_id = first_ticket_issue_id(order_id)

      assert {:error, :reason_required} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :admin,
                 actor_id: "admin-1",
                 allowed_event_ids: [event.id]
               )
    end

    test "system actor requires correlation_id or idempotency_key" do
      ticket_issue_id = first_ticket_issue_id(issued_order_fixture().order_id)

      assert {:error, :audit_context_required} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :system,
                 actor_id: "sys"
               )
    end

    test "admin actor without allowed_event_ids is forbidden" do
      ticket_issue_id = first_ticket_issue_id(issued_order_fixture().order_id)

      assert {:error, :forbidden} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :admin,
                 actor_id: "admin-1",
                 reason: "manual_review"
               )
    end

    test "admin actor cannot revoke ticket outside allowed_event_ids" do
      %{order_id: order_id} = issued_order_fixture()
      ticket_issue_id = first_ticket_issue_id(order_id)
      other_event = create_event()

      assert {:error, :forbidden} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :admin,
                 actor_id: "admin-1",
                 reason: "manual_review",
                 allowed_event_ids: [other_event.id]
               )
    end

    test "operator actor cannot revoke ticket outside allowed_event_ids" do
      %{order_id: order_id, event: event} = issued_order_fixture()
      ticket_issue_id = first_ticket_issue_id(order_id)
      other_event = create_event()

      assert {:error, :forbidden} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :operator,
                 actor_id: "op-1",
                 reason: "cancel",
                 allowed_event_ids: [other_event.id]
               )

      assert ticket_issue_row(ticket_issue_id).status == "issued"

      assert {:ok, %{status: :revoked}} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :operator,
                 actor_id: "op-1",
                 reason: "cancel",
                 allowed_event_ids: [event.id]
               )
    end

    test "missing attendee returns explicit error" do
      %{order_id: order_id} = issued_order_fixture()
      ticket_issue_id = first_ticket_issue_id(order_id)

      Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
        999_999_999,
        ticket_issue_id
      ])

      assert {:error, {:missing_attendee, ^ticket_issue_id}} =
               Revocation.revoke_ticket_issue(ticket_issue_id,
                 actor_type: :system,
                 actor_id: "test",
                 correlation_id: "corr-missing",
                 reason: "cancel"
               )
    end

    test "logs do not include buyer email or ticket codes" do
      %{order_id: order_id} = issued_order_fixture()
      ticket_issue_id = first_ticket_issue_id(order_id)
      row = ticket_issue_row(ticket_issue_id)

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   Revocation.revoke_ticket_issue(ticket_issue_id,
                     actor_type: :system,
                     actor_id: "test",
                     correlation_id: "corr-log",
                     reason: "cancel"
                   )
        end)

      refute log =~ "buyer@example.com"
      refute log =~ row.ticket_code
    end
  end

  describe "revoke_order_tickets/2" do
    test "revokes multiple issued tickets with one event sync bump" do
      %{order_id: order_id, event: event} = issued_order_fixture(quantity: 3)
      version_before = event_sync_version(event.id)

      assert {:ok, %{revoked: revoked, failures: []}} =
               Revocation.revoke_order_tickets(order_id,
                 actor_type: :system,
                 actor_id: "test",
                 correlation_id: "corr-batch",
                 reason: "cancel"
               )

      assert length(revoked) == 3
      assert Enum.all?(revoked, &(&1.status == :revoked))
      assert event_sync_version(event.id) == version_before + 1

      issued_count =
        Repo.one!(
          from t in "sales_ticket_issues",
            where: t.sales_order_id == ^order_id and t.status == "issued",
            select: count(t.id)
        )

      assert issued_count == 0
    end

    test "list_issued_by_order excludes revoked tickets at query layer" do
      %{order_id: order_id} = issued_order_fixture(quantity: 2)
      [first_id, second_id] = ticket_issue_ids(order_id)

      assert {:ok, %{status: :revoked}} =
               Revocation.revoke_ticket_issue(first_id,
                 actor_type: :system,
                 actor_id: "test",
                 correlation_id: "corr-one",
                 reason: "cancel"
               )

      issued_ids =
        FastCheck.Sales.TicketIssue
        |> Ash.Query.for_read(:list_issued_by_order, %{sales_order_id: order_id})
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert issued_ids == [second_id]
    end

    test "batch sync bump failure rolls back ticket and attendee mutations" do
      %{order_id: order_id, event: event} = issued_order_fixture(quantity: 3)
      ticket_ids = ticket_issue_ids(order_id)
      version_before = event_sync_version(event.id)
      attendee_ids = Enum.map(ticket_ids, &ticket_issue_row(&1).attendee_id)

      batch_opts = [
        actor_type: :system,
        actor_id: "test",
        correlation_id: "corr-batch-fail",
        reason: "cancel",
        mobile_sync_version_aggregator: FastCheck.Tickets.RevocationTest.FailingAggregator
      ]

      assert {:error, {:mobile_sync_version_aggregation_failed, :forced_failure}} =
               Revocation.revoke_order_tickets(order_id, batch_opts)

      assert event_sync_version(event.id) == version_before

      for ticket_id <- ticket_ids do
        assert ticket_issue_row(ticket_id).status == "issued"
      end

      for attendee_id <- attendee_ids do
        attendee = Repo.get!(Attendee, attendee_id)
        assert attendee.scan_eligibility == "active"
        assert invalidation_count(attendee_id) == 0
      end
    end

    test "retry after failed batch sync can still succeed" do
      %{order_id: order_id, event: event} = issued_order_fixture(quantity: 3)
      version_before = event_sync_version(event.id)

      assert {:error, {:mobile_sync_version_aggregation_failed, :forced_failure}} =
               Revocation.revoke_order_tickets(order_id,
                 actor_type: :system,
                 actor_id: "test",
                 correlation_id: "corr-batch-retry-fail",
                 reason: "cancel",
                 mobile_sync_version_aggregator:
                   FastCheck.Tickets.RevocationTest.FailingAggregator
               )

      assert {:ok, %{revoked: revoked, failures: []}} =
               Revocation.revoke_order_tickets(order_id,
                 actor_type: :system,
                 actor_id: "test",
                 correlation_id: "corr-batch-retry-ok",
                 reason: "cancel"
               )

      assert length(revoked) == 3
      assert Enum.all?(revoked, &(&1.status == :revoked))
      assert event_sync_version(event.id) == version_before + 1
    end
  end

  defmodule FailingAggregator do
    def after_attendees_created(_event_id, _ticket_codes, _opts), do: {:error, :forced_failure}

    def after_attendee_invalidated(_event_id, _attendee_id, _ticket_code, _reason_code, _opts),
      do: {:error, :forced_failure}
  end

  defp issued_order_fixture(opts \\ []) do
    quantity = Keyword.get(opts, :quantity, 1)
    event = create_event()
    unit_amount = 12_500
    total = quantity * unit_amount
    offer_id = insert_offer!(event.id, unit_amount)
    order_id = insert_order!(event.id, "paid_verified", total)
    line_id = insert_order_line!(order_id, offer_id, quantity, unit_amount, total)
    insert_checkout_session!(order_id, "paid", quantity)
    insert_payment_attempt!(order_id, "verified_success", total)

    assert {:ok, %{status: :ticket_issued}} = Issuer.issue_order(order_id)

    %{event: event, order_id: order_id, line_id: line_id}
  end

  defp ticket_issue_ids(order_id) do
    Repo.all(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id,
        order_by: [asc: t.id],
        select: t.id
    )
  end

  defp first_ticket_issue_id(order_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id,
        select: t.id,
        limit: 1
    )
  end

  defp ticket_issue_row(ticket_issue_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.id == ^ticket_issue_id,
        select: %{
          id: t.id,
          attendee_id: t.attendee_id,
          ticket_code: t.ticket_code,
          status: t.status,
          revoked_at: t.revoked_at,
          revocation_reason: t.revocation_reason,
          scanner_status: t.scanner_status,
          delivery_token_expires_at: t.delivery_token_expires_at,
          sales_order_id: t.sales_order_id
        }
    )
  end

  defp event_sync_version(event_id) do
    Repo.one!(from e in Event, where: e.id == ^event_id, select: e.event_sync_version)
  end

  defp event_sync_version_for_ticket_issue(ticket_issue_id) do
    event_id =
      Repo.one!(
        from t in "sales_ticket_issues",
          join: o in "sales_orders",
          on: o.id == t.sales_order_id,
          where: t.id == ^ticket_issue_id,
          select: o.event_id
      )

    event_sync_version(event_id)
  end

  defp invalidation_count(attendee_id) do
    Repo.one!(
      from i in AttendeeInvalidationEvent,
        where: i.attendee_id == ^attendee_id,
        select: count(i.id)
    )
  end

  defp revoke_transition_count(ticket_issue_id) do
    Repo.one!(
      from st in "sales_state_transitions",
        where:
          st.entity_type == "TicketIssue" and
            st.entity_id == ^Integer.to_string(ticket_issue_id) and
            st.to_state == "revoked",
        select: count(st.id)
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
        [event_id, "Revocation Offer #{System.unique_integer([:positive])}", price_cents]
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
          ($1, $2, 1, 'General Admission', 'General Admission', 'Revocation Event',
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
end
