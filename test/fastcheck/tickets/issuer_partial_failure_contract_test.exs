defmodule FastCheck.Tickets.IssuerPartialFailureContractTest do
  use ExUnit.Case, async: true

  @failure_matrix_path "docs/fastcheck_sales/ticket_issuance_failure_matrix.md"
  @contract_path "docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md"

  @required_recovery_cases [
    "Existing Attendee found but TicketIssue missing",
    "TicketIssue exists but Attendee link missing",
    "Order transition fails after all units exist",
    "Event sync enqueue fails after commit",
    "One ticket in multi-ticket order fails",
    "Duplicate worker after full issuance"
  ]

  @required_reason_codes [
    "issuer_attendee_conflict",
    "issuer_ticket_issue_conflict",
    "issuer_partial_attendee_created",
    "issuer_partial_ticket_issue_created",
    "issuer_state_transition_failed",
    "issuer_event_sync_enqueue_failed",
    "issuer_unrecoverable_invariant_violation",
    "issuer_inventory_not_confirmed",
    "issuer_invalid_payment_state"
  ]

  test "failure matrix document exists and links partial issuance policy" do
    doc = File.read!(@failure_matrix_path)

    assert doc =~ "PARTIAL_TICKET_ISSUANCE_POLICY"
    assert doc =~ "partially_issued"
    assert doc =~ "manual_review"
  end

  test "failure matrix documents required recovery paths" do
    doc = File.read!(@failure_matrix_path)

    for case_label <- @required_recovery_cases do
      assert doc =~ case_label, "missing recovery case: #{case_label}"
    end
  end

  test "failure matrix defines stable issuer manual_review reason codes" do
    doc = File.read!(@failure_matrix_path)

    for code <- @required_reason_codes do
      assert doc =~ code, "missing reason code: #{code}"
    end
  end

  test "contract forbids marking full ticket_issued on partial multi-ticket failure" do
    contract = File.read!(@contract_path)
    matrix = File.read!(@failure_matrix_path)

    assert contract =~ "partially_issued"
    assert matrix =~ "Do **not** mark full `ticket_issued`"
  end

  test "contract requires StateTransition audit for issuance outcomes" do
    contract = File.read!(@contract_path)

    assert contract =~ "StateTransitionSupport.record!"
    assert contract =~ "correlation_id"
    assert contract =~ "idempotency_key"
    assert contract =~ "issued_count"
  end
end
