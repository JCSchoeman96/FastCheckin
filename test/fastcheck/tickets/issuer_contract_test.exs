defmodule FastCheck.Tickets.IssuerContractTest do
  use ExUnit.Case, async: true

  @contract_path "docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md"
  @failure_matrix_path "docs/fastcheck_sales/ticket_issuance_failure_matrix.md"
  @idempotency_path "docs/fastcheck_sales/ticket_issuance_idempotency_keys.md"

  test "VS-09A contract documents exist" do
    for path <- [@contract_path, @failure_matrix_path, @idempotency_path] do
      assert File.exists?(path), "expected #{path}"
    end
  end

  test "contract names single FastCheck.Repo transaction model with advisory lock" do
    contract = File.read!(@contract_path)

    assert contract =~ "single `FastCheck.Repo` transaction"
    assert contract =~ "pg_advisory_xact_lock"
    refute contract =~ "saga/recovery model is required"
  end

  test "contract documents approved issuer entrypoint and worker boundary" do
    contract = File.read!(@contract_path)

    assert contract =~ "FastCheck.Tickets.Issuer.issue_order"
    assert contract =~ "FastCheck.Workers.IssueTicketsWorker"
    assert contract =~ "controllers"
    assert contract =~ "Forbidden direct issuers"
  end

  test "contract lists preconditions for order payment checkout attendee origin and tokens" do
    contract = File.read!(@contract_path)

    assert contract =~ "### 6.1 Order preconditions"
    assert contract =~ "### 6.2 Payment preconditions"
    assert contract =~ "### 6.3 Checkout / inventory preconditions"
    assert contract =~ "### 6.4 Attendee protection preconditions"
    assert contract =~ "### 6.5 Token preconditions"
  end

  test "contract documents VS-09B VS-09C VS-09D split" do
    contract = File.read!(@contract_path)

    assert contract =~ "VS-09B"
    assert contract =~ "VS-09C"
    assert contract =~ "VS-09D"
  end

  test "contract documents logging redaction rules" do
    contract = File.read!(@contract_path)

    assert contract =~ "Redactor"
    assert contract =~ "buyer_phone"
    assert contract =~ "plaintext"
  end
end
