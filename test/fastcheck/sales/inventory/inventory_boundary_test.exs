defmodule FastCheck.Sales.Inventory.InventoryBoundaryTest do
  use ExUnit.Case, async: true

  @inventory_mutation_allowlist [
    "lib/fastcheck/sales/inventory/reservation_ledger.ex",
    "lib/fastcheck/sales/inventory/redis_scripts.ex"
  ]

  test "only ReservationLedger and RedisScripts own sales inventory mutation commands" do
    inventory_hits =
      [
        "lib/fastcheck/sales/**/*.ex",
        "lib/fastcheck_web/**/*.ex",
        "lib/fastcheck/**/*.ex"
      ]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn file ->
        case File.read(file) do
          {:ok, content} ->
            if String.contains?(content, "sales:offer:") or
                 String.contains?(content, "sales:hold:") or
                 String.contains?(content, "sales:inventory:dedupe:") do
              [file]
            else
              []
            end

          _ ->
            []
        end
      end)
      |> Enum.reject(&String.starts_with?(&1, "test/"))
      |> Enum.uniq()

    assert Enum.member?(inventory_hits, "lib/fastcheck/sales/inventory/reservation_ledger.ex")

    assert Enum.all?(inventory_hits, fn path ->
             path in @inventory_mutation_allowlist
           end)
  end
end
