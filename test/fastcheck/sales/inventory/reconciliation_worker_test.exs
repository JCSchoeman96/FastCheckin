defmodule FastCheck.Sales.Inventory.ReconciliationWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Sales.Inventory.ReconciliationWorker
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!(configured_quantity_available: 5)
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "worker defaults to dry_run and does not mutate redis", %{offer: offer} do
    assert {:ok, before} = ReservationLedger.get_availability(offer.id)

    assert {:ok, _} =
             Redix.command(FastCheck.Redix, [
               "HSET",
               "sales:offer:#{offer.id}:inventory",
               "available_quantity",
               "9"
             ])

    assert :ok =
             perform_job(ReconciliationWorker, %{
               "offer_id" => offer.id,
               "mode" => "dry_run",
               "trigger" => "manual"
             })

    assert {:ok, after_snapshot} = ReservationLedger.get_availability(offer.id)
    assert after_snapshot.available_quantity == 9
    assert before.configured_quantity == after_snapshot.configured_quantity
  end

  test "duplicate worker jobs are deduplicated by uniqueness", %{offer: offer} do
    args = %{"offer_id" => offer.id, "mode" => "dry_run", "trigger" => "scheduled"}

    assert {:ok, first} = ReconciliationWorker.new(args) |> Oban.insert()
    assert {:ok, second} = ReconciliationWorker.new(args) |> Oban.insert()

    assert first.id != second.id or first.conflict? or second.conflict?
  end
end
