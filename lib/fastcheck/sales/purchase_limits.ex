defmodule FastCheck.Sales.PurchaseLimits do
  @moduledoc """
  Platform-wide customer purchase limits for commercial Orders.

  This policy constrains new customer checkout and configuration. It does not
  constrain historical Orders or ticket revocation.
  """

  @max_tickets_per_order 50

  @spec max_tickets_per_order() :: pos_integer()
  def max_tickets_per_order, do: @max_tickets_per_order

  @spec validate_quantity(term()) ::
          :ok | {:error, :invalid_quantity | :platform_max_per_order_exceeded}
  def validate_quantity(quantity) when is_integer(quantity) and quantity > 0 do
    if quantity <= max_tickets_per_order(),
      do: :ok,
      else: {:error, :platform_max_per_order_exceeded}
  end

  def validate_quantity(_), do: {:error, :invalid_quantity}
end
