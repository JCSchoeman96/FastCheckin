defmodule FastCheck.Sales.PurchaseLimitsTest do
  use ExUnit.Case, async: true

  alias FastCheck.Sales.PurchaseLimits

  test "the platform maximum is 50 tickets per Order" do
    assert PurchaseLimits.max_tickets_per_order() == 50
  end

  test "quantity validation accepts 50 and rejects 51 with the stable domain error" do
    assert :ok = PurchaseLimits.validate_quantity(50)

    assert {:error, :platform_max_per_order_exceeded} =
             PurchaseLimits.validate_quantity(51)
  end

  test "quantity validation preserves the invalid quantity error" do
    assert {:error, :invalid_quantity} = PurchaseLimits.validate_quantity(0)
    assert {:error, :invalid_quantity} = PurchaseLimits.validate_quantity("51")
  end
end
