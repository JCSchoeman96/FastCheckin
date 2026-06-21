defmodule FastCheck.Workers.IssueTicketsWorkerContractTest do
  use ExUnit.Case, async: true

  @contract_path "docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md"
  @worker_path "lib/fastcheck/workers/issue_tickets_worker.ex"

  test "IssueTicketsWorker implementation exists after VS-13" do
    assert File.exists?(@worker_path)
  end

  test "contract documents worker queue uniqueness and issuer-only caller" do
    contract = File.read!(@contract_path)

    assert contract =~ "FastCheck.Workers.IssueTicketsWorker"
    assert contract =~ ":ticketing"
    assert contract =~ "Only worker allowed to call"
    assert contract =~ "FastCheck.Tickets.Issuer.issue_order"
    assert contract =~ "sales_order_id"
    assert contract =~ "correlation_id"
    assert contract =~ "idempotency_key"
  end

  test "contract forbids worker output of PII tokens and provider payloads" do
    contract = File.read!(@contract_path)

    assert contract =~ "buyer phone/email"
    assert contract =~ "plaintext"
    assert contract =~ "raw Paystack"
  end

  test "contract requires fresh state load and post-commit event sync enqueue" do
    contract = File.read!(@contract_path)

    assert contract =~ "Load fresh state"
    assert contract =~ "after commit"
    assert contract =~ "EventSyncVersionAggregatorWorker"
  end

  test "implementation remains a minimal issuer-only Oban boundary" do
    source = File.read!(@worker_path)

    assert source =~ "use Oban.Worker"
    assert source =~ "queue: :ticketing"
    assert source =~ "Issuer.issue_order"
    refute source =~ "FastCheck.Attendees.Attendee"
    refute source =~ "FastCheck.Sales.TicketIssue"
    refute source =~ "DeliveryAttempt"
    refute source =~ "Paystack"
    refute source =~ "ReservationLedger"
  end
end
