defmodule FastCheck.Sales.AdminRefundsTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias Ash.Changeset
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
    %{order_id: order_id} = Fixtures.issued_order_fixture()

    assert {:ok, %{order: order, revoke: %{failures: []}}} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.admin_actor(),
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

  test "operator cannot mark order refunded" do
    %{order_id: order_id} = Fixtures.issued_order_fixture()

    assert {:error, :forbidden} =
             AdminRefunds.mark_order_refunded_manual(
               Fixtures.operator_actor(),
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
               Fixtures.admin_actor(),
               order_id,
               Fixtures.admin_attrs()
             )
  end

  test "mark_order_refunded_manual blocked when revoke_order_tickets returns failures" do
    %{order_id: order_id, ticket_issue_ids: [ticket_issue_id | _]} =
      Fixtures.issued_order_fixture()

    Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
      9_999_999,
      ticket_issue_id
    ])

    result =
      AdminRefunds.mark_order_refunded_manual(
        Fixtures.admin_actor(),
        order_id,
        Fixtures.admin_attrs()
      )

    assert {:error, {:revoke_failures, [_ | _]}} = result
    assert Fixtures.order_status(order_id) != "refunded"
  end

  test "already refunded order is idempotent without duplicate StateTransition rows" do
    %{order_id: order_id} = Fixtures.issued_order_fixture()

    actor = Fixtures.admin_actor()

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
               Fixtures.admin_actor(),
               order_id,
               Fixtures.admin_attrs()
             )

    assert order.status == "cancelled"
  end

  test "mark_refunded_manual Ash action is idempotent" do
    %{order_id: order_id, event: event} = Fixtures.issued_order_fixture()
    actor = %{actor_type: :admin, actor_id: "admin", allowed_event_ids: [event.id]}

    order =
      Order |> Ash.Query.for_read(:get_by_id, %{id: order_id}) |> Ash.read_one!(authorize?: false)

    order =
      order
      |> Changeset.for_update(:mark_refunded_manual, %{reason: "first"}, actor: actor)
      |> Ash.update!(authorize?: false)

    assert order.status == "refunded"
    count_after_first = Fixtures.order_transition_count(order_id, "refunded")

    order =
      order
      |> Changeset.for_update(:mark_refunded_manual, %{reason: "retry"}, actor: actor)
      |> Ash.update!(authorize?: false)

    assert order.status == "refunded"
    assert Fixtures.order_transition_count(order_id, "refunded") == count_after_first
  end

  defp insert_minimal_event! do
    FastCheckWeb.SalesWebFixtures.insert_event!()
  end
end
