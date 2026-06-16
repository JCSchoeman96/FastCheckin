defmodule FastCheck.Sales.Inventory.HealthTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.Inventory.Health
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!(configured_quantity_available: 10)
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "offer_health reports healthy redis inventory", %{offer: offer} do
    assert {:ok, report} = Health.offer_health(offer.id)
    assert report.status == :healthy
    assert report.redis_present?
    assert report.redis_available == 10
    assert report.safe_available == 10
    refute report.manual_review_required?
  end

  test "offer_health reports missing redis keys after simulated redis loss", %{offer: offer} do
    assert {:ok, _} = ReservationLedger.get_availability(offer.id)
    assert {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", "sales:offer:#{offer.id}:inventory"])

    assert {:ok, report} = Health.offer_health(offer.id)
    assert report.status == :missing_redis_inventory
    refute report.redis_present?
    assert report.drift_detected?
  end
end
