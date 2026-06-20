defmodule FastCheck.Tickets.IssuerIdempotencyContractTest do
  use ExUnit.Case, async: true

  @contract_path "docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md"
  @idempotency_path "docs/fastcheck_sales/ticket_issuance_idempotency_keys.md"

  test "idempotency doc defines deterministic line_item_sequence from quantity" do
    doc = File.read!(@idempotency_path)

    assert doc =~ "line_item_sequence"
    assert doc =~ "1..order_line.quantity"
    assert doc =~ "never"
    assert doc =~ "count(existing_rows)"
  end

  test "idempotency doc maps ticket issue and order constraints" do
    doc = File.read!(@idempotency_path)

    assert doc =~ "sales_ticket_issues_order_line_sequence_uidx"
    assert doc =~ "sales_ticket_issues_ticket_code_uidx"
    assert doc =~ "sales_ticket_issues_attendee_id_uidx"
    assert doc =~ "sales_orders_public_reference_uidx"
    assert doc =~ "sales_payment_attempts_provider_reference_uidx"
  end

  test "idempotency doc flags attendee origin unique gap for VS-09B" do
    doc = File.read!(@idempotency_path)

    assert doc =~ "VS-09B"
    assert doc =~ "fastcheck_sales"
    assert doc =~ "Missing"
  end

  test "contract requires idempotent success when order already ticket_issued" do
    contract = File.read!(@contract_path)
    idempotency = File.read!(@idempotency_path)

    assert contract =~ ":already_issued"
    assert idempotency =~ "already `ticket_issued`"
    assert idempotency =~ "infinite retry"
  end

  test "duplicate worker behavior is documented as DB constraint backed" do
    doc = File.read!(@idempotency_path)

    assert doc =~ "Duplicate worker"
    assert doc =~ "Oban uniqueness"
    assert doc =~ "DB unique constraints"
  end
end
