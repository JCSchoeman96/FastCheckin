defmodule FastCheck.Sales.AdminRefundsTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Attendees.Scan
  alias FastCheck.Repo
  alias FastCheck.Sales.AdminRefundFixtures, as: Fixtures
  alias FastCheck.Sales.AdminRefunds
  alias FastCheck.Sales.Order

  setup do
    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: "admin",
      password: Fixtures.dashboard_password()
    })

    :ok
  end

  test "mark_order_refunded_manual revokes tickets then marks order refunded" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()

    assert {:ok, %{order: order, revoke: %{failures: []}}} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs()
             )

    assert order.status == "refunded"
    assert Fixtures.order_status(order_id) == "refunded"

    assert Repo.aggregate(
             from(t in "sales_ticket_issues",
               where: t.sales_order_id == ^order_id and t.status == "revoked"
             ),
             :count
           ) >= 1
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
               Fixtures.admin_attrs()
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

    assert {:error, {:revoke_failures, [%{ticket_issue_id: ^failed_issue_id}]}} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs()
             )

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
               Fixtures.admin_attrs()
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
               Fixtures.admin_attrs()
             )
  end

  test "admin out of scope event cannot mark order refunded" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()

    assert {:error, :forbidden} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.out_of_scope_admin_actor(event.id),
               order_id,
               Fixtures.admin_attrs()
             )
  end

  test "operator cannot mark order refunded" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()

    assert {:error, :forbidden} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.operator_actor(event_id: event.id),
               order_id,
               Fixtures.admin_attrs()
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
               Fixtures.admin_attrs()
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
        Fixtures.admin_attrs()
      )

    assert {:error, {:revoke_failures, [_ | _]}} = result
    assert Fixtures.order_status(order_id) != "refunded"
  end

  test "already refunded order is idempotent without duplicate StateTransition rows" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()

    actor = Fixtures.admin_actor(event_id: event.id)

    assert {:ok, _} =
             AdminRefunds.mark_order_refunded_manual(actor, order_id, Fixtures.admin_attrs())

    count_before = Fixtures.order_transition_count(order_id, "refunded")

    assert {:ok, %{order: order}} =
             AdminRefunds.mark_order_refunded_manual(
               actor,
               order_id,
               Fixtures.admin_attrs(%{"idempotency_key" => "retry-refund"})
             )

    assert order.status == "refunded"
    assert Fixtures.order_transition_count(order_id, "refunded") == count_before
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
               Fixtures.admin_attrs()
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

    for action <- [:mark_refunded_manual, :mark_cancelled_manual] do
      assert {:error, %Ash.Error.Invalid{}} =
               order
               |> Changeset.for_update(action, %{reason: "must revoke first"}, actor: actor)
               |> Ash.update(authorize?: false)

      assert Fixtures.order_status(order_id) == "ticket_issued"
    end

    assert issued_ticket_count(order_id) == 1
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
