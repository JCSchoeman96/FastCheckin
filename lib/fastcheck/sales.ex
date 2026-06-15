defmodule FastCheck.Sales do
  @moduledoc """
  Ash domain boundary for FastCheck Sales.

  VS-01C registers durable core and checkout/payment resource skeletons only.
  Inventory, workflow actions, Paystack integration, delivery, ticket issuance,
  and scanner behavior are added by later approved slices.
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
  end
end
