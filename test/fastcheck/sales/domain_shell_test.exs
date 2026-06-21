defmodule FastCheck.Sales.DomainShellTest do
  use ExUnit.Case, async: true

  @expected_resource_modules [
    FastCheck.Sales.TicketOffer,
    FastCheck.Sales.Order,
    FastCheck.Sales.OrderLine,
    FastCheck.Sales.StateTransition,
    FastCheck.Sales.CheckoutSession,
    FastCheck.Sales.PaymentAttempt,
    FastCheck.Sales.PaymentEvent,
    FastCheck.Sales.TicketIssue,
    FastCheck.Sales.DeliveryAttempt,
    FastCheck.Sales.Conversation
  ]

  test "FastCheck.Sales exists and is registered as the Ash domain" do
    assert {:module, FastCheck.Sales} = Code.ensure_loaded(FastCheck.Sales)
    assert Code.ensure_loaded?(Ash.Domain.Info)
    assert FastCheck.Sales in Application.fetch_env!(:fastcheck, :ash_domains)
  end

  test "FastCheck.Sales registers exactly the VS-01E sales resources" do
    assert Ash.Domain.Info.resources(FastCheck.Sales) == @expected_resource_modules
  end

  test "VS-01E resource modules are available" do
    for module <- @expected_resource_modules do
      assert Code.ensure_loaded?(module), "#{inspect(module)} must exist through VS-01E"
    end
  end

  test "only VS-05 Sales resource and policy helper files exist" do
    assert Path.wildcard("priv/repo/migrations/*sales*.exs") != []

    assert Path.wildcard("lib/fastcheck/sales/*.ex") |> Enum.sort() == [
             "lib/fastcheck/sales/checkout.ex",
             "lib/fastcheck/sales/checkout_session.ex",
             "lib/fastcheck/sales/conversation.ex",
             "lib/fastcheck/sales/delivery_attempt.ex",
             "lib/fastcheck/sales/order.ex",
             "lib/fastcheck/sales/order_line.ex",
             "lib/fastcheck/sales/payment_attempt.ex",
             "lib/fastcheck/sales/payment_event.ex",
             "lib/fastcheck/sales/policy_checks.ex",
             "lib/fastcheck/sales/secondary_entrypoints.ex",
             "lib/fastcheck/sales/state_transition.ex",
             "lib/fastcheck/sales/state_transition_support.ex",
             "lib/fastcheck/sales/ticket_issue.ex",
             "lib/fastcheck/sales/ticket_offer.ex",
             "lib/fastcheck/sales/ticket_page.ex"
           ]
  end
end
