defmodule FastCheck.Sales.TicketOfferBoundaryTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo

  @forbidden_paths [
    "lib/fastcheck/sales/inventory",
    "lib/fastcheck/payments/paystack",
    "lib/fastcheck/messaging/whatsapp",
    "lib/fastcheck/tickets",
    "lib/fastcheck_web/live/sales",
    "lib/fastcheck_web/controllers/webhooks/paystack_controller.ex",
    "lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex"
  ]

  @forbidden_action_names [
    :create_session,
    :reserve_inventory,
    :consume_reservation,
    :release_hold,
    :create_order,
    :create_order_line,
    :initialize_payment,
    :verify_payment,
    :issue_ticket
  ]

  test "VS-03 keeps TicketOffer as durable config only" do
    for action_name <- @forbidden_action_names do
      refute ResourceInfo.action(FastCheck.Sales.TicketOffer, action_name),
             "FastCheck.Sales.TicketOffer must not expose #{inspect(action_name)} in VS-03"
    end
  end

  test "forbidden runtime paths remain absent in VS-03" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for VS-03"
    end
  end

  test "existing scanner, mobile and Android surfaces remain untouched in VS-03" do
    changed_files =
      System.cmd("git", ["diff", "--name-only", "main...HEAD"])
      |> elem(0)
      |> String.split("\n", trim: true)

    forbidden_changed_prefixes = [
      "android/",
      "lib/fastcheck_web/controllers/mobile/",
      "lib/fastcheck_web/live/scanner",
      "lib/fastcheck_web/router.ex"
    ]

    for file <- changed_files,
        prefix <- forbidden_changed_prefixes,
        String.starts_with?(file, prefix) do
      flunk("#{file} must not change in VS-03")
    end
  end
end
