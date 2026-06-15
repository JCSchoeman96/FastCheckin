defmodule FastCheck.Sales do
  @moduledoc """
  Ash domain boundary for FastCheck Sales.

  VS-01B registers the durable core Sales resource skeletons only. Checkout,
  payment, inventory, delivery, ticket issuance, and scanner behavior are added
  by later approved slices.
  """

  use Ash.Domain, otp_app: :fastcheck

  resources do
    resource(FastCheck.Sales.TicketOffer)
    resource(FastCheck.Sales.Order)
    resource(FastCheck.Sales.OrderLine)
    resource(FastCheck.Sales.StateTransition)
  end
end
