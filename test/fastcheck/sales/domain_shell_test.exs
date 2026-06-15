defmodule FastCheck.Sales.DomainShellTest do
  use ExUnit.Case, async: true

  @forbidden_resource_modules [
    FastCheck.Sales.TicketOffer,
    FastCheck.Sales.Order,
    FastCheck.Sales.OrderLine,
    FastCheck.Sales.CheckoutSession,
    FastCheck.Sales.PaymentAttempt,
    FastCheck.Sales.PaymentEvent,
    FastCheck.Sales.TicketIssue,
    FastCheck.Sales.DeliveryAttempt,
    FastCheck.Sales.Conversation,
    FastCheck.Sales.StateTransition
  ]

  test "FastCheck.Sales exists and is registered as the Ash domain" do
    assert {:module, FastCheck.Sales} = Code.ensure_loaded(FastCheck.Sales)
    assert Code.ensure_loaded?(Ash.Domain.Info)
    assert FastCheck.Sales in Application.fetch_env!(:fastcheck, :ash_domains)
  end

  test "FastCheck.Sales has no registered resources in VS-01A" do
    assert Ash.Domain.Info.resources(FastCheck.Sales) == []
  end

  test "future Sales resource modules are not available yet" do
    for module <- @forbidden_resource_modules do
      refute Code.ensure_loaded?(module), "#{inspect(module)} must not exist in VS-01A"
    end
  end

  test "no Sales migrations or resource files exist yet" do
    assert Path.wildcard("priv/repo/migrations/*sales*.exs") == []
    assert Path.wildcard("lib/fastcheck/sales/*.ex") == []
  end
end
