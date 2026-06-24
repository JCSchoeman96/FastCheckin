defmodule FastCheck.Sales.AdminRevocationsTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.Scan
  alias FastCheck.Repo
  alias FastCheck.Sales.AdminRefundFixtures, as: Fixtures
  alias FastCheck.Sales.AdminRevocations

  defmodule FailingAggregator do
    def after_attendees_created(_event_id, _ticket_codes, _opts), do: {:error, :forced_failure}

    def after_attendee_invalidated(_event_id, _attendee_id, _ticket_code, _reason_code, _opts),
      do: {:error, :forced_failure}
  end

  setup do
    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: "admin",
      password: Fixtures.dashboard_password()
    })

    :ok
  end

  test "admin revokes single issued ticket with reason through Revocation" do
    %{order_id: order_id, ticket_issue_ids: [ticket_issue_id | _], event: event} =
      Fixtures.issued_order_fixture()

    assert {:ok, %{status: :revoked}} =
             AdminRevocations.revoke_ticket_issue(
               Fixtures.admin_actor(),
               ticket_issue_id,
               Fixtures.admin_attrs(%{"confirmed_bulk" => nil, "admin_password" => nil})
             )

    attendee_id =
      Repo.one!(
        from t in "sales_ticket_issues", where: t.id == ^ticket_issue_id, select: t.attendee_id
      )

    assert Repo.get!(Attendee, attendee_id).scan_eligibility == "not_scannable"

    assert {:error, "TICKET_NOT_SCANNABLE", _} =
             Scan.check_in(
               event.id,
               Repo.one!(
                 from t in "sales_ticket_issues",
                   where: t.id == ^ticket_issue_id,
                   select: t.ticket_code
               ),
               "Main",
               "Op"
             )

    assert Fixtures.order_status(order_id) == "ticket_issued"
  end

  test "missing reason blocks revocation" do
    %{ticket_issue_ids: [ticket_issue_id | _]} = Fixtures.issued_order_fixture()

    assert {:error, :reason_required} =
             AdminRevocations.revoke_ticket_issue(
               Fixtures.admin_actor(),
               ticket_issue_id,
               %{"reason" => "  "}
             )
  end

  test "order-level revoke requires bulk confirmation and admin password" do
    %{order_id: order_id} = Fixtures.issued_order_fixture()

    assert {:error, :bulk_confirmation_required} =
             AdminRevocations.revoke_order_tickets(
               Fixtures.admin_actor(),
               order_id,
               Fixtures.admin_attrs(%{"confirmed_bulk" => nil})
             )

    assert {:error, :invalid_admin_password} =
             AdminRevocations.revoke_order_tickets(
               Fixtures.admin_actor(),
               order_id,
               Fixtures.admin_attrs(%{"admin_password" => "wrong-password"})
             )
  end

  test "operator cannot perform admin-only order-level revoke" do
    %{order_id: order_id} = Fixtures.issued_order_fixture()

    assert {:error, :forbidden} =
             AdminRevocations.revoke_order_tickets(
               Fixtures.operator_actor(),
               order_id,
               Fixtures.admin_attrs()
             )
  end

  test "sync aggregation failure surfaces error without persisting batch revoke" do
    %{order_id: order_id, ticket_issue_ids: ticket_issue_ids} =
      Fixtures.issued_order_fixture(quantity: 2)

    assert {:error, {:mobile_sync_version_aggregation_failed, :forced_failure}} =
             AdminRevocations.revoke_order_tickets(
               Fixtures.admin_actor(),
               order_id,
               Fixtures.admin_attrs(%{
                 "mobile_sync_version_aggregator" => FailingAggregator
               })
             )

    for ticket_issue_id <- ticket_issue_ids do
      assert Repo.one!(
               from t in "sales_ticket_issues", where: t.id == ^ticket_issue_id, select: t.status
             ) ==
               "issued"
    end
  end

  test "order revoke with missing attendee collects failures" do
    %{order_id: order_id, ticket_issue_ids: [ticket_issue_id | _]} =
      Fixtures.issued_order_fixture()

    Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
      9_999_999,
      ticket_issue_id
    ])

    assert {:ok, %{failures: [failure | _]}} =
             AdminRevocations.revoke_order_tickets(
               Fixtures.admin_actor(),
               order_id,
               Fixtures.admin_attrs()
             )

    assert failure.ticket_issue_id == ticket_issue_id
  end

  test "admin modules do not expose per-ticket refund marker API" do
    refute function_exported?(FastCheck.Sales.AdminRefunds, :mark_ticket_issue_refunded_manual, 3)
    refute function_exported?(FastCheck.Sales.AdminRevocations, :retry_core_revocation, 3)
  end
end
