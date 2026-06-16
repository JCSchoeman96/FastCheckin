defmodule FastCheckWeb.Sales.SecondaryEntrypointsBoundaryTest do
  use ExUnit.Case, async: true

  @scanned_files [
    "lib/fastcheck/sales/secondary_entrypoints.ex",
    "lib/fastcheck_web/live/sales/admin_checkout_live.ex",
    "lib/fastcheck_web/live/sales/internal_pilot_checkout_live.ex"
  ]

  @forbidden_fragments [
    "Redix",
    "sales:offer:",
    "sales:hold:",
    "Paystack",
    "WhatsApp",
    "TicketIssue",
    "Attendee",
    "CheckoutSession |> Changeset",
    "Order |> Changeset",
    "OrderLine |> Changeset"
  ]

  test "secondary entrypoint source files exist and stay within boundary" do
    for path <- @scanned_files do
      assert File.exists?(path), "expected #{path} to exist"
      source = File.read!(path)

      for fragment <- @forbidden_fragments do
        refute String.contains?(source, fragment),
               "#{path} must not contain #{inspect(fragment)}"
      end
    end
  end

  test "only SecondaryEntrypoints may call Checkout.start_checkout" do
    source = File.read!("lib/fastcheck/sales/secondary_entrypoints.ex")
    assert source =~ "Checkout.start_checkout"
  end
end
