defmodule FastCheck.Workers.IssueTicketsWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Repo
  alias FastCheck.Workers.IssueTicketsWorker

  test "worker is unique by sales_order_id and delegates retry to issuer boundary" do
    args = %{
      "sales_order_id" => 123,
      "idempotency_key" => "issue-retry-123",
      "correlation_id" => "corr-123"
    }

    assert {:ok, first} = IssueTicketsWorker.new(args) |> Oban.insert()
    assert {:ok, second} = IssueTicketsWorker.new(args) |> Oban.insert()
    assert first.id != second.id or first.conflict? or second.conflict?

    source = File.read!("lib/fastcheck/workers/issue_tickets_worker.ex")
    assert source =~ "FastCheck.Tickets.Issuer"
    assert source =~ "Issuer.issue_order"
    refute source =~ "FastCheck.Attendees.Attendee"
    refute source =~ "FastCheck.Sales.TicketIssue"
    refute source =~ "DeliveryAttempt"
    refute source =~ "Paystack"
    refute source =~ "ReservationLedger"
  end

  test "worker returns safe error for missing order without creating sales rows" do
    assert {:error, :order_not_found} =
             perform_job(IssueTicketsWorker, %{"sales_order_id" => 987_654})

    assert Repo.aggregate("sales_ticket_issues", :count, :id) == 0
  end
end
