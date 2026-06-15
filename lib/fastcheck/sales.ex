defmodule FastCheck.Sales do
  @moduledoc """
  Ash domain boundary for FastCheck Sales.

  VS-01D registers durable core, checkout/payment, and ticket/delivery audit
  resource skeletons only. Inventory, workflow actions, Paystack integration,
  delivery sending, ticket issuance, and scanner behavior are added by later
  approved slices.
  """

  use Ash.Domain, otp_app: :fastcheck

  resources do
    resource(FastCheck.Sales.TicketOffer)
    resource(FastCheck.Sales.Order)
    resource(FastCheck.Sales.OrderLine)
    resource(FastCheck.Sales.StateTransition)
    resource(FastCheck.Sales.CheckoutSession)
    resource(FastCheck.Sales.PaymentAttempt)
    resource(FastCheck.Sales.PaymentEvent)
    resource(FastCheck.Sales.TicketIssue)
    resource(FastCheck.Sales.DeliveryAttempt)
  end
end
