defmodule FastCheck.Tickets.IssuerBoundaryTest do
  use ExUnit.Case, async: true

  @issuer_path "lib/fastcheck/tickets/issuer.ex"
  @issuer_source File.read!("lib/fastcheck/tickets/issuer.ex")

  @forbidden_payment_terms ~w(
    TicketIssue
    Attendee
    IssueTicketsWorker
  )

  @forbidden_issuer_aliases [
    "alias FastCheck.Workers.IssueTicketsWorker"
  ]

  @forbidden_issuer_calls [
    "Oban.insert",
    "Paystack",
    "IssueTicketsWorker",
    "DeliveryAttempt",
    "ReservationLedger",
    "Redix.command",
    "mark_partially_issued"
  ]

  @handler_source File.read!("lib/fastcheck/sales/payments/payment_outcome_handler.ex")
  @outcomes_source File.read!("lib/fastcheck/sales/payments/payment_outcomes.ex")
  @verification_source File.read!("lib/fastcheck/sales/payments/payment_verification.ex")

  test "VS-09C issuer ticket issue linking entrypoint exists" do
    assert File.exists?(@issuer_path)
    assert Code.ensure_loaded?(FastCheck.Tickets.Issuer)
    assert function_exported?(FastCheck.Tickets.Issuer, :issue_order, 2)
  end

  test "issuer uses approved VS-09C ticket issue and token boundaries" do
    assert @issuer_source =~ "alias FastCheck.Sales.TicketIssue"
    assert @issuer_source =~ "alias FastCheck.Tickets.DeliveryToken"
    assert @issuer_source =~ "alias FastCheck.Tickets.QrPayload"
    assert @issuer_source =~ "create_issued_link"
    assert @issuer_source =~ "mark_ticket_issued"
  end

  test "issuer attendee bridge does not alias forbidden later-slice modules" do
    for fragment <- @forbidden_issuer_aliases do
      refute String.contains?(@issuer_source, fragment),
             "issuer must not #{fragment}"
    end
  end

  test "issuer attendee bridge does not call forbidden later-slice APIs" do
    for fragment <- @forbidden_issuer_calls do
      refute String.contains?(@issuer_source, fragment),
             "issuer must not reference #{fragment}"
    end
  end

  test "payment outcome modules do not reference forbidden issuance domains" do
    for source <- [@handler_source, @outcomes_source, @verification_source],
        term <- @forbidden_payment_terms do
      refute String.contains?(source, term),
             "payment module must not reference #{term}"
    end
  end

  test "VS-13 IssueTicketsWorker exists without coupling the issuer to the worker" do
    assert File.exists?("lib/fastcheck/workers/issue_tickets_worker.ex")
    assert Code.ensure_loaded?(FastCheck.Workers.IssueTicketsWorker)
    refute @issuer_source =~ "IssueTicketsWorker"
  end
end
