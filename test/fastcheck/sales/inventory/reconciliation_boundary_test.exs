defmodule FastCheck.Sales.Inventory.ReconciliationBoundaryTest do
  use ExUnit.Case, async: true

  @reconciliation_modules [
    "lib/fastcheck/sales/inventory/health.ex",
    "lib/fastcheck/sales/inventory/reconciler.ex",
    "lib/fastcheck/sales/inventory/recovery.ex",
    "lib/fastcheck/sales/inventory/durable_snapshot.ex",
    "lib/fastcheck/sales/inventory/reconciliation_worker.ex"
  ]

  @inventory_mutation_allowlist [
    "lib/fastcheck/sales/inventory/reservation_ledger.ex",
    "lib/fastcheck/sales/inventory/redis_scripts.ex"
  ]

  test "reconciliation modules do not embed sales inventory redis key strings" do
    Enum.each(@reconciliation_modules, fn path ->
      refute File.read!(path) =~ "sales:offer:"
      refute File.read!(path) =~ "sales:hold:"
      refute File.read!(path) =~ "sales:inventory:dedupe:"
    end)
  end

  test "only ReservationLedger and RedisScripts own sales inventory mutation commands" do
    inventory_hits =
      [
        "lib/fastcheck/sales/**/*.ex",
        "lib/fastcheck/workers/**/*.ex",
        "lib/fastcheck/**/*.ex"
      ]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn file ->
        case File.read(file) do
          {:ok, content} ->
            if String.contains?(content, "sales:offer:") or
                 String.contains?(content, "sales:hold:") or
                 String.contains?(content, "sales:order:") or
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

    assert Enum.all?(inventory_hits, fn path -> path in @inventory_mutation_allowlist end)
  end
end
