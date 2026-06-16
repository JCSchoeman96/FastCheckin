defmodule FastCheck.Sales.CheckoutInventoryBoundaryTest do
  use ExUnit.Case, async: true

  @allowed_inventory_modules [
    FastCheck.Sales.Inventory.ReservationLedger,
    FastCheck.Sales.Inventory.RedisScripts
  ]

  @allowed_inventory_paths [
    "lib/fastcheck/sales/inventory/reservation_ledger.ex",
    "lib/fastcheck/sales/inventory/redis_scripts.ex"
  ]

  test "checkout module does not reference direct redis inventory key writes" do
    source = File.read!("lib/fastcheck/sales/checkout.ex")

    refute source =~ ~s|"HSET"|
    refute source =~ ~s|Redix.command|
    refute source =~ "sales:offer:"
  end

  test "checkout delegates inventory to ReservationLedger" do
    source = File.read!("lib/fastcheck/sales/checkout.ex")
    assert source =~ "ReservationLedger.reserve"
    assert source =~ "ReservationLedger.release"
    assert source =~ "ReservationLedger.hold_key"
  end

  test "only approved modules own inventory redis mutation key strings" do
    lib_root = Path.expand("lib", File.cwd!())

    offenders =
      lib_root
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.reject(&allowed_inventory_file?/1)
      |> Enum.filter(fn path ->
        content = File.read!(path)
        String.contains?(content, "sales:offer:") or String.contains?(content, "sales:hold:")
      end)

    assert offenders == [],
           "unexpected inventory key references: #{inspect(Enum.map(offenders, &Path.relative_to(&1, lib_root)))}"
  end

  defp allowed_inventory_file?(path) do
    normalized = path |> Path.expand() |> String.replace("\\", "/")

    Enum.any?(@allowed_inventory_paths, &String.ends_with?(normalized, &1)) or
      inventory_module?(path)
  end

  defp inventory_module?(path) do
    module =
      path
      |> Path.relative_to(Path.expand("lib", File.cwd!()))
      |> String.trim_trailing(".ex")
      |> String.split("/")
      |> Module.concat()

    module in @allowed_inventory_modules
  end
end
