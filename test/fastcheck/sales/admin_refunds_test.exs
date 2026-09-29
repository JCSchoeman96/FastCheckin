defmodule FastCheck.Sales.AdminRefundsTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Attendees.Scan
  alias FastCheck.Repo
  alias FastCheck.Sales.AdminRefundFixtures, as: Fixtures
  alias FastCheck.Sales.AdminRefunds
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.Refund

  setup do
    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: "admin",
      password: Fixtures.dashboard_password()
    })

    :ok
  end

  test "admin refund records provider evidence, revokes tickets, and queues inventory resolution" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()
    attrs = Fixtures.admin_attrs_for_order(order_id)

    assert {:ok, %{order: order, refund: refund, revoke: %{failures: []}}} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               attrs
             )

    assert order.status == "refunded"
    assert Fixtures.order_status(order_id) == "refunded"
    assert refund.status == "inventory_pending"
    assert refund.provider == "paystack"
    assert refund.provider_status == "processed"
    assert refund.provider_refund_reference == attrs["provider_refund_reference"]
    assert refund.amount_cents == String.to_integer(attrs["amount_cents"])
    assert refund.currency == attrs["currency"]

    payment_evidence = payment_attempt_evidence(order_id)
    refute is_nil(payment_evidence.provider_reference)
    refute is_nil(payment_evidence.provider_paid_at)
    refute is_nil(payment_evidence.verified_at)
    refute is_nil(payment_evidence.raw_verify_response)

    assert Repo.one!(
             from attempt in "sales_payment_attempts",
               where: attempt.sales_order_id == ^order_id,
               select: attempt.status
           ) == "refunded"

    assert [%{args: %{"refund_id" => refund_id}}] =
             all_enqueued(worker: FastCheck.Workers.RefundInventoryWorker)
             |> Enum.filter(&(&1.args["refund_id"] == refund.id))

    assert refund_id == refund.id

    assert Repo.aggregate(
             from(t in "sales_ticket_issues",
               where: t.sales_order_id == ^order_id and t.status == "revoked"
             ),
             :count
           ) >= 1
  end

  test "Refund evidence action requires an event-scoped admin with the existing password" do
    fixture = Fixtures.issued_order_fixture()
    evidence = refund_evidence_attrs(fixture)

    assert {:error, _} =
             create_refund_evidence(evidence, Fixtures.admin_actor(event_id: fixture.event.id))

    assert {:error, _} =
             create_refund_evidence(
               Map.put(evidence, :admin_password, Fixtures.dashboard_password()),
               Fixtures.out_of_scope_admin_actor(fixture.event.id)
             )

    refute Repo.exists?(
             from refund in "sales_refunds", where: refund.sales_order_id == ^fixture.order_id
           )
  end

  test "admin refund revokes all 60 historical tickets before the Order transition" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture(quantity: 60)
    ticket_issue_ids = Fixtures.ticket_issue_ids(order_id)

    assert {:ok,
            %{
              order: %{status: "refunded"},
              revoke: %{revoked: revoked, failures: [], remaining_issued_count: 0}
            }} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs_for_order(order_id)
             )

    assert length(ticket_issue_ids) == 60
    assert length(revoked) == 60
    assert issued_ticket_count(order_id) == 0

    assert Repo.aggregate(
             from(t in "sales_ticket_issues",
               where: t.sales_order_id == ^order_id and t.status == "revoked"
             ),
             :count
           ) == 60

    assert_order_tickets_not_scannable(event.id, ticket_issue_ids, [0, 59])
  end

  test "admin refund cannot transition after a page-two ticket fails, then succeeds after retry" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture(quantity: 60)
    ticket_issue_ids = Fixtures.ticket_issue_ids(order_id)
    failed_issue_id = Enum.at(ticket_issue_ids, 54)
    attendee_id = issue_attendee_id(failed_issue_id)
    ticket_code = issue_ticket_code(failed_issue_id)

    Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
      9_999_999,
      failed_issue_id
    ])

    attrs = Fixtures.admin_attrs_for_order(order_id)

    assert {:error, {:revoke_failures, [%{ticket_issue_id: ^failed_issue_id}]}} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               attrs
             )

    assert Repo.one!(
             from refund in "sales_refunds",
               where: refund.sales_order_id == ^order_id,
               select: refund.status
           ) == "revocation_manual_review"

    assert Repo.one!(
             from refund in "sales_refunds",
               where: refund.sales_order_id == ^order_id,
               select: refund.provider_refund_reference
           ) == attrs["provider_refund_reference"]

    assert Repo.one!(
             from attempt in "sales_payment_attempts",
               where: attempt.sales_order_id == ^order_id,
               select: attempt.status
           ) == "verified_success"

    assert Fixtures.order_status(order_id) == "manual_review"
    assert issued_ticket_count(order_id) == 1
    assert Repo.get!(FastCheck.Attendees.Attendee, attendee_id).scan_eligibility == "active"
    assert {:ok, _attendee, "SUCCESS"} = Scan.check_in(event.id, ticket_code, "Main", "Operator")

    Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
      attendee_id,
      failed_issue_id
    ])

    assert {:ok,
            %{
              order: %{status: "refunded"},
              revoke: %{failures: [], remaining_issued_count: 0}
            }} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               attrs
             )

    assert issued_ticket_count(order_id) == 0
    assert Enum.all?(ticket_issue_ids, &(issue_status(&1) == "revoked"))

    assert {:error, "TICKET_NOT_SCANNABLE", _} =
             Scan.check_in(event.id, ticket_code, "Main", "Operator")
  end

  test "admin without allowed_event_ids cannot mark order refunded" do
    %{order_id: order_id} = Fixtures.issued_order_fixture()

    assert {:error, :forbidden} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(),
               order_id,
               Fixtures.admin_attrs_for_order(order_id)
             )
  end

  test "admin out of scope event cannot mark order refunded" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()

    assert {:error, :forbidden} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.out_of_scope_admin_actor(event.id),
               order_id,
               Fixtures.admin_attrs_for_order(order_id)
             )
  end

  test "operator cannot mark order refunded" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()

    assert {:error, :forbidden} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.operator_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs_for_order(order_id)
             )
  end

  test "mark_order_refunded_manual blocked without verified payment context" do
    event = insert_minimal_event!()

    %{rows: [[order_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, source_channel, status, total_amount_cents,
           currency, lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer', 'admin', 'awaiting_payment', 1000, 'ZAR', 1, now(), now())
        RETURNING id
        """,
        ["NO-PAY-#{System.unique_integer([:positive])}", event.id]
      )

    assert {:error, :verified_payment_required} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs_for_order(order_id)
             )
  end

  test "mark_order_refunded_manual blocked when revoke_order_tickets returns failures" do
    %{order_id: order_id, ticket_issue_ids: [ticket_issue_id | _], event: event} =
      Fixtures.issued_order_fixture()

    Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
      9_999_999,
      ticket_issue_id
    ])

    result =
      AdminRefunds.mark_order_refunded_manual(
        Fixtures.admin_actor(event_id: event.id),
        order_id,
        Fixtures.admin_attrs_for_order(order_id)
      )

    assert {:error, {:revoke_failures, [_ | _]}} = result
    assert Fixtures.order_status(order_id) != "refunded"
  end

  test "already refunded order is idempotent without duplicate StateTransition rows" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()

    actor = Fixtures.admin_actor(event_id: event.id)

    attrs = Fixtures.admin_attrs_for_order(order_id)

    assert {:ok, _} = AdminRefunds.mark_order_refunded_manual(actor, order_id, attrs)

    count_before = Fixtures.order_transition_count(order_id, "refunded")

    assert {:ok, %{order: order}} =
             AdminRefunds.mark_order_refunded_manual(
               actor,
               order_id,
               Map.put(attrs, "idempotency_key", "retry-refund")
             )

    assert order.status == "refunded"
    assert Fixtures.order_transition_count(order_id, "refunded") == count_before
  end

  test "conflicting provider refund evidence is rejected for an existing durable refund" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()
    actor = Fixtures.admin_actor(event_id: event.id)
    attrs = Fixtures.admin_attrs_for_order(order_id)

    assert {:ok, _} = AdminRefunds.mark_order_refunded_manual(actor, order_id, attrs)

    assert {:error, :conflicting_refund_evidence} =
             AdminRefunds.mark_order_refunded_manual(
               actor,
               order_id,
               Map.put(attrs, "provider_refund_reference", "DIFFERENT-RRN")
             )
  end

  test "admin retry moves inventory_manual_review back to pending and enqueues by refund id" do
    fixture = Fixtures.inventory_pending_refund_fixture()

    Repo.query!(
      "UPDATE sales_refunds SET status = 'inventory_manual_review', manual_review_reason = 'review' WHERE id = $1",
      [fixture.refund_id]
    )

    attrs = %{
      "reason" => "Verified the refund hold against the order",
      "admin_password" => Fixtures.dashboard_password()
    }

    assert {:ok, %{refund: refund, order: %{status: "refunded"}}} =
             AdminRefunds.retry_refund_inventory(
               Fixtures.admin_actor(event_id: fixture.event.id),
               fixture.order_id,
               attrs
             )

    assert refund.status == "inventory_pending"

    assert [%{args: %{"refund_id" => refund_id}}] =
             all_enqueued(worker: FastCheck.Workers.RefundInventoryWorker)
             |> Enum.filter(&(&1.args["refund_id"] == fixture.refund_id))

    assert refund_id == fixture.refund_id

    assert Repo.exists?(
             from transition in "sales_state_transitions",
               where:
                 transition.entity_type == "Refund" and
                   transition.entity_id == ^to_string(fixture.refund_id) and
                   transition.from_state == "inventory_manual_review" and
                   transition.to_state == "inventory_pending" and
                   transition.reason == ^attrs["reason"]
           )
  end

  test "inventory worker insert failure rolls back financial finalization" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()
    constraint = "fail_refund_inventory_worker_insert_for_test"

    Repo.query!(
      "ALTER TABLE oban_jobs ADD CONSTRAINT #{constraint} CHECK (worker <> 'FastCheck.Workers.RefundInventoryWorker') NOT VALID"
    )

    try do
      assert {:error, {:refund_inventory_job_insert_failed, _reason}} =
               AdminRefunds.mark_order_refunded_manual(
                 Fixtures.admin_actor(event_id: event.id),
                 order_id,
                 Fixtures.admin_attrs_for_order(order_id)
               )

      assert Fixtures.order_status(order_id) == "ticket_issued"
      assert issued_ticket_count(order_id) == 0

      assert Repo.one!(
               from attempt in "sales_payment_attempts",
                 where: attempt.sales_order_id == ^order_id,
                 select: attempt.status
             ) == "verified_success"

      assert Repo.one!(
               from refund in "sales_refunds",
                 where: refund.sales_order_id == ^order_id,
                 select: refund.status
             ) == "revocation_complete"
    after
      Repo.query!("ALTER TABLE oban_jobs DROP CONSTRAINT #{constraint}")
    end
  end

  test "admin inventory retry rejects an Order no longer refunded" do
    fixture = Fixtures.inventory_pending_refund_fixture()

    Repo.query!(
      "UPDATE sales_refunds SET status = 'inventory_manual_review' WHERE id = $1",
      [fixture.refund_id]
    )

    Repo.query!("UPDATE sales_orders SET status = 'paid_verified' WHERE id = $1", [
      fixture.order_id
    ])

    assert {:error, :invalid_order_state} =
             AdminRefunds.retry_refund_inventory(
               Fixtures.admin_actor(event_id: fixture.event.id),
               fixture.order_id,
               %{
                 "reason" => "Retry check",
                 "admin_password" => Fixtures.dashboard_password()
               }
             )

    assert Repo.one!(
             from refund in "sales_refunds",
               where: refund.id == ^fixture.refund_id,
               select: refund.status
           ) == "inventory_manual_review"
  end

  test "refund evidence requires a processed Paystack reference and timestamp" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()
    actor = Fixtures.admin_actor(event_id: event.id)
    attrs = Fixtures.admin_attrs_for_order(order_id)

    assert {:error, :provider_refund_reference_required} =
             AdminRefunds.mark_order_refunded_manual(
               actor,
               order_id,
               Map.put(attrs, "provider_refund_reference", " ")
             )

    assert {:error, :provider_refund_not_processed} =
             AdminRefunds.mark_order_refunded_manual(
               actor,
               order_id,
               Map.put(attrs, "provider_status", "pending")
             )

    assert {:error, :provider_refunded_at_required} =
             AdminRefunds.mark_order_refunded_manual(
               actor,
               order_id,
               Map.put(attrs, "provider_refunded_at", "invalid")
             )
  end

  test "partial amount and currency mismatch are rejected" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()
    actor = Fixtures.admin_actor(event_id: event.id)
    attrs = Fixtures.admin_attrs_for_order(order_id)

    assert {:error, :partial_refund_not_supported} =
             AdminRefunds.mark_order_refunded_manual(
               actor,
               order_id,
               Map.put(attrs, "amount_cents", "100")
             )

    assert {:error, :refund_currency_mismatch} =
             AdminRefunds.mark_order_refunded_manual(
               actor,
               order_id,
               Map.put(attrs, "currency", "USD")
             )
  end

  test "multiple verified-success attempts fail closed" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()

    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, status, amount_cents, currency,
         verification_attempt_count, inserted_at, updated_at)
      SELECT sales_order_id, provider, 'second-' || provider_reference, 'verified_success',
             amount_cents, currency, 1, now(), now()
      FROM sales_payment_attempts WHERE sales_order_id = $1
      """,
      [order_id]
    )

    assert {:error, :ambiguous_payment_attempt} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs_for_order(order_id)
             )

    assert Fixtures.order_status(order_id) != "refunded"
  end

  test "verified-success PaymentAttempt from another provider cannot back a Paystack refund" do
    %{order_id: order_id, event: event, payment_attempt_id: payment_attempt_id} =
      Fixtures.issued_order_fixture()

    Repo.query!("UPDATE sales_payment_attempts SET provider = 'stripe' WHERE id = $1", [
      payment_attempt_id
    ])

    assert {:error, :refund_provider_mismatch} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs_for_order(order_id)
             )

    refute Repo.exists?(from refund in "sales_refunds", where: refund.sales_order_id == ^order_id)
    assert Fixtures.order_status(order_id) == "ticket_issued"
  end

  test "get_order_operations_context is bounded and uses SQL counts" do
    %{order_id: order_id} = Fixtures.issued_order_fixture(quantity: 2)

    assert {:ok, context} = AdminRefunds.get_order_operations_context(order_id, limit: 1)

    assert context.issued_ticket_count == 2
    assert length(context.ticket_rows) == 1
    assert length(context.timeline) <= 25
    assert is_binary(context.buyer_email_masked)
    refute context.buyer_email_masked =~ "buyer@example.com"
  end

  test "mark_order_cancelled_manual transitions paid_verified order without issued tickets" do
    event = insert_minimal_event!()

    %{rows: [[order_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, source_channel, status, total_amount_cents,
           currency, lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer', 'admin', 'paid_verified', 1000, 'ZAR', 1, now(), now())
        RETURNING id
        """,
        ["CANCEL-#{System.unique_integer([:positive])}", event.id]
      )

    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, status, amount_cents, currency,
         verification_attempt_count, inserted_at, updated_at)
      VALUES ($1, 'paystack', 'pv-ref', 'verified_success', 1000, 'ZAR', 1, now(), now())
      """,
      [order_id]
    )

    assert {:ok, %{order: order}} =
             AdminRefunds.mark_order_cancelled_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs_for_order(order_id)
             )

    assert order.status == "cancelled"
  end

  test "admin cancellation revokes all 60 historical tickets before the Order transition" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture(quantity: 60)
    ticket_issue_ids = Fixtures.ticket_issue_ids(order_id)

    assert {:ok,
            %{
              order: %{status: "cancelled"},
              revoke: %{revoked: revoked, failures: [], remaining_issued_count: 0}
            }} =
             AdminRefunds.mark_order_cancelled_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs()
             )

    assert length(revoked) == 60
    assert issued_ticket_count(order_id) == 0
    assert_order_tickets_not_scannable(event.id, ticket_issue_ids, [0, 59])
  end

  test "admin cancellation cannot transition after a page-two failure and completes on retry" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture(quantity: 60)
    ticket_issue_ids = Fixtures.ticket_issue_ids(order_id)
    failed_issue_id = Enum.at(ticket_issue_ids, 54)
    attendee_id = issue_attendee_id(failed_issue_id)
    ticket_code = issue_ticket_code(failed_issue_id)

    Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
      9_999_999,
      failed_issue_id
    ])

    assert {:error, {:revoke_failures, [%{ticket_issue_id: ^failed_issue_id}]}} =
             AdminRefunds.mark_order_cancelled_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs()
             )

    assert Fixtures.order_status(order_id) == "manual_review"
    assert issued_ticket_count(order_id) == 1
    assert {:ok, _attendee, "SUCCESS"} = Scan.check_in(event.id, ticket_code, "Main", "Operator")

    Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
      attendee_id,
      failed_issue_id
    ])

    assert {:ok,
            %{
              order: %{status: "cancelled"},
              revoke: %{failures: [], remaining_issued_count: 0}
            }} =
             AdminRefunds.mark_order_cancelled_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs()
             )

    assert issued_ticket_count(order_id) == 0
    assert Enum.all?(ticket_issue_ids, &(issue_status(&1) == "revoked"))

    assert {:error, "TICKET_NOT_SCANNABLE", _} =
             Scan.check_in(event.id, ticket_code, "Main", "Operator")
  end

  test "direct Ash refund and cancellation actions refuse Orders with issued tickets" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()
    actor = %{actor_type: :admin, actor_id: "admin", allowed_event_ids: [event.id]}

    order =
      Order |> Ash.Query.for_read(:get_by_id, %{id: order_id}) |> Ash.read_one!(authorize?: false)

    for action <- [:finalize_refund, :mark_cancelled_manual] do
      assert {:error, %Ash.Error.Invalid{}} =
               order
               |> Changeset.for_update(action, %{reason: "must revoke first"}, actor: actor)
               |> Ash.update(authorize?: false)

      assert Fixtures.order_status(order_id) == "ticket_issued"
    end

    assert issued_ticket_count(order_id) == 1
  end

  test "direct Ash refund action cannot create a naked refunded Order" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()
    actor = %{actor_type: :admin, actor_id: "admin", allowed_event_ids: [event.id]}

    assert {:ok, %{failures: [], remaining_issued_count: 0}} =
             FastCheck.Sales.AdminRevocations.revoke_order_tickets(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs()
             )

    order =
      Order |> Ash.Query.for_read(:get_by_id, %{id: order_id}) |> Ash.read_one!(authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} =
             order
             |> Changeset.for_update(
               :finalize_refund,
               %{reason: "must include a durable refund"},
               actor: actor
             )
             |> Ash.update(authorize?: false)

    assert Fixtures.order_status(order_id) == "ticket_issued"
  end

  defp insert_minimal_event! do
    FastCheckWeb.SalesWebFixtures.insert_event!()
  end

  defp issued_ticket_count(order_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id and t.status == "issued",
        select: count(t.id)
    )
  end

  defp create_refund_evidence(attrs, actor) do
    Refund
    |> Changeset.for_create(:record_full_refund_evidence, attrs, actor: actor)
    |> Ash.create(authorize?: false, context: %{actor: actor})
  end

  defp refund_evidence_attrs(fixture) do
    %{
      sales_order_id: fixture.order_id,
      payment_attempt_id: fixture.payment_attempt_id,
      provider_refund_reference: "DIRECT-RRN-#{System.unique_integer([:positive])}",
      provider_refunded_at: DateTime.utc_now() |> DateTime.truncate(:second),
      amount_cents: fixture.amount_cents,
      currency: fixture.currency,
      reason: "Direct action policy test"
    }
  end

  defp issue_attendee_id(ticket_issue_id) do
    Repo.one!(
      from t in "sales_ticket_issues", where: t.id == ^ticket_issue_id, select: t.attendee_id
    )
  end

  defp issue_ticket_code(ticket_issue_id) do
    Repo.one!(
      from t in "sales_ticket_issues", where: t.id == ^ticket_issue_id, select: t.ticket_code
    )
  end

  defp issue_status(ticket_issue_id) do
    Repo.one!(from t in "sales_ticket_issues", where: t.id == ^ticket_issue_id, select: t.status)
  end

  defp payment_attempt_evidence(order_id) do
    Repo.one!(
      from attempt in "sales_payment_attempts",
        where: attempt.sales_order_id == ^order_id,
        select: %{
          provider_reference: attempt.provider_reference,
          provider_paid_at: attempt.provider_paid_at,
          verified_at: attempt.verified_at,
          raw_verify_response: attempt.raw_verify_response
        }
    )
  end

  defp assert_order_tickets_not_scannable(event_id, issue_ids, indexes) do
    for index <- indexes do
      assert {:error, "TICKET_NOT_SCANNABLE", _} =
               Scan.check_in(
                 event_id,
                 issue_ticket_code(Enum.at(issue_ids, index)),
                 "Main",
                 "Operator"
               )
    end
  end
end
