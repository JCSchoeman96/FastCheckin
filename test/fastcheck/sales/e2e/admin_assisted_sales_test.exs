defmodule FastCheck.Sales.E2E.AdminAssistedSalesTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport
  alias FastCheck.Sales.Payments.TransactionInitialization
  alias FastCheck.Sales.SecondaryEntrypoints
  alias FastCheck.SalesCheckoutFixtures
  alias FastCheck.SalesE2EFixtures, as: E2E
  alias FastCheck.Workers.IssueTicketsWorker

  @moduletag :e2e
  @moduletag :sales
  @moduletag :payments
  @moduletag :slow

  @admin_user %{id: "admin", username: "admin"}

  setup do
    paystack_cleanup = PaystackSupport.setup_paystack!()
    {event, admin_offer} = E2E.setup_sales_event_offer!(sales_channel: "admin")
    {_event, internal_offer} = E2E.setup_sales_event_offer!(sales_channel: "internal")

    on_exit(fn ->
      SalesCheckoutFixtures.flush_inventory_keys(admin_offer.id)
      SalesCheckoutFixtures.flush_inventory_keys(internal_offer.id)
      paystack_cleanup.()
    end)

    {:ok, event: event, admin_offer: admin_offer, internal_offer: internal_offer}
  end

  test "admin-assisted checkout uses shared Sales core through payment, issuance, and scanner-visible attendee",
       %{event: event, admin_offer: offer} do
    idem = SecondaryEntrypoints.generate_idempotency_key()

    assert {:ok, %{order_id: order_id}} =
             SecondaryEntrypoints.start_admin_checkout(
               @admin_user,
               event.id,
               %{
                 "ticket_offer_id" => to_string(offer.id),
                 "quantity" => "1",
                 "buyer_name" => "Admin Buyer",
                 "buyer_email" => "admin-buyer@example.com"
               },
               idem
             )

    order = E2E.reload_order!(order_id)
    session = E2E.checkout_session_for_order!(order.id)
    assert order.source_channel == "admin"
    assert E2E.inventory_snapshot!(offer.id).reserved_quantity == 1

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaystackSupport.init_and_verify_request_fun(amount: order.total_amount_cents)
    )

    {:ok, init} =
      TransactionInitialization.initialize_for_checkout_session(
        session.id,
        SalesCheckoutFixtures.system_actor([event.id])
      )

    attempt = E2E.reload_payment_attempt!(init.payment_attempt_id)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaystackSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)

    assert :ok =
             perform_job(IssueTicketsWorker, %{
               "sales_order_id" => order.id,
               "correlation_id" => E2E.e2e_id("issue-admin"),
               "idempotency_key" => E2E.e2e_id("issue-admin")
             })

    assert E2E.reload_order!(order.id).status == "ticket_issued"

    assert E2E.sales_counts(order.id) == %{
             attendees: 1,
             ticket_issues: 1,
             issued_ticket_issues: 1
           }
  end

  test "internal pilot remains selected pre-launch scope while public web checkout is absent", %{
    internal_offer: offer
  } do
    idem = SecondaryEntrypoints.generate_idempotency_key()

    assert {:ok, %{order_id: order_id}} =
             SecondaryEntrypoints.start_internal_pilot_checkout(
               @admin_user,
               offer.event_id,
               %{
                 "ticket_offer_id" => to_string(offer.id),
                 "quantity" => "1",
                 "buyer_name" => "Pilot Buyer",
                 "buyer_email" => "pilot@example.com"
               },
               idem
             )

    assert E2E.reload_order!(order_id).source_channel == "internal_pilot"
    assert E2E.inventory_snapshot!(offer.id).reserved_quantity == 1
  end
end
