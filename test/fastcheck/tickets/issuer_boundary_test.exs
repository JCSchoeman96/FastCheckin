defmodule FastCheck.Tickets.IssuerBoundaryTest do
  use ExUnit.Case, async: true

  @issuer_path "lib/fastcheck/tickets/issuer.ex"
  @issuer_source File.read!("lib/fastcheck/tickets/issuer.ex")

  @forbidden_payment_terms ~w(
    TicketIssue
    Attendee
    IssueTicketsWorker
  )

  @forbidden_issuer_aliases ~w(
    alias FastCheck.Repo
    alias Ash
    alias FastCheck.Attendees
    alias FastCheck.Sales.TicketIssue
    alias FastCheck.Tickets.CodeGenerator
  )

  @forbidden_issuer_calls ~w(
    Repo.
    Ash.create
    Ash.update
    CodeGenerator.generate
    Oban.insert
  )

  @handler_source File.read!("lib/fastcheck/sales/payments/payment_outcome_handler.ex")
  @outcomes_source File.read!("lib/fastcheck/sales/payments/payment_outcomes.ex")
  @verification_source File.read!("lib/fastcheck/sales/payments/payment_verification.ex")

  test "VS-09A issuer contract stub exists and raises not implemented" do
    assert File.exists?(@issuer_path)
    assert Code.ensure_loaded?(FastCheck.Tickets.Issuer)

    assert_raise RuntimeError, "not implemented until VS-09B", fn ->
      FastCheck.Tickets.Issuer.issue_order(1)
    end
  end

  test "issuer stub does not alias forbidden modules" do
    for fragment <- @forbidden_issuer_aliases do
      refute String.contains?(@issuer_source, fragment),
             "issuer stub must not #{fragment}"
    end
  end

  test "issuer stub does not call forbidden runtime APIs" do
    for fragment <- @forbidden_issuer_calls do
      refute String.contains?(@issuer_source, fragment),
             "issuer stub must not reference #{fragment}"
    end
  end

  test "payment outcome modules do not reference forbidden issuance domains" do
    for source <- [@handler_source, @outcomes_source, @verification_source],
        term <- @forbidden_payment_terms do
      refute String.contains?(source, term),
             "payment module must not reference #{term}"
    end
  end

  test "IssueTicketsWorker implementation path remains absent" do
    refute File.exists?("lib/fastcheck/workers/issue_tickets_worker.ex")
    refute Code.ensure_loaded?(FastCheck.Workers.IssueTicketsWorker)
  end
end
