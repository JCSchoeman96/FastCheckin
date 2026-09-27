defmodule FastCheck.Sales.PaidOrderFulfillmentBoundaryTest do
  use ExUnit.Case, async: true

  @coordinator File.read!("lib/fastcheck/sales/paid_order_fulfillment.ex")
  @payment_handler File.read!("lib/fastcheck/sales/payments/payment_outcome_handler.ex")
  @payment_verification File.read!("lib/fastcheck/sales/payments/payment_verification.ex")
  @issuer File.read!("lib/fastcheck/tickets/issuer.ex")
  @issuer_worker File.read!("lib/fastcheck/workers/issue_tickets_worker.ex")

  test "fulfillment owns consume and issuer enqueue but not payment or ticket creation" do
    assert @coordinator =~ "ReservationLedger.consume"
    assert @coordinator =~ "IssueTicketsWorker"
    refute @coordinator =~ "Paystack"
    refute @coordinator =~ "Attendee"
    refute @coordinator =~ "TicketIssue"
    refute @coordinator =~ "DeliveryAttempt"
  end

  test "payment verification only creates the durable fulfillment handoff" do
    assert @payment_handler =~ "PaidOrderFulfillmentWorker"
    refute @payment_handler =~ "IssueTicketsWorker"
    refute @payment_handler =~ "Issuer.issue_order"
    refute @payment_verification =~ "ReservationLedger"
  end

  test "issuer does not mutate inventory or call payment providers" do
    refute @issuer =~ "ReservationLedger"
    refute @issuer =~ "Paystack"
    refute @issuer =~ "paid_verified"
  end

  test "issuer worker does not mutate inventory or call payment providers" do
    refute @issuer_worker =~ "ReservationLedger"
    refute @issuer_worker =~ "Paystack"
  end
end
