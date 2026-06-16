defmodule FastCheck.Sales.Inventory.ReservationLedgerConcurrencyTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.Inventory.ReservationLedger

  @offer_id 44_002

  setup do
    _ = Redix.command(FastCheck.Redix, ["DEL", "sales:offer:#{@offer_id}:inventory"])
    _ = Redix.command(FastCheck.Redix, ["DEL", "sales:offer:#{@offer_id}:holds"])
    assert :ok = ReservationLedger.initialize_offer(@offer_id, 10)
    :ok
  end

  test "parallel reserve attempts cannot oversell" do
    run_id = System.unique_integer([:positive])

    results =
      1..25
      |> Task.async_stream(
        fn idx ->
          ReservationLedger.reserve(
            @offer_id,
            "ORD-C-#{run_id}-#{idx}",
            1,
            120,
            "idem-c-#{run_id}-#{idx}"
          )
        end,
        max_concurrency: 25,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    success_count = Enum.count(results, &match?({:ok, _}, &1))

    failure_count =
      Enum.count(results, fn
        {:error, :insufficient_inventory, _meta} -> true
        _ -> false
      end)

    assert success_count == 10
    assert failure_count == 15

    assert {:ok, availability} = ReservationLedger.get_availability(@offer_id)
    assert availability.available_quantity == 0
    assert availability.reserved_quantity == 10
    assert availability.consumed_quantity == 0
  end
end
