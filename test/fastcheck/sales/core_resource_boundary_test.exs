defmodule FastCheck.Sales.CoreResourceBoundaryTest do
  use ExUnit.Case, async: true

  @forbidden_resource_modules []

  @forbidden_paths [
    "lib/fastcheck/payments/paystack",
    "lib/fastcheck/messaging/whatsapp",
    "lib/fastcheck/tickets",
    "lib/fastcheck_web/controllers/webhooks/paystack_controller.ex",
    "lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex"
  ]

  test "later Sales resources are not implemented through VS-01D" do
    for module <- @forbidden_resource_modules do
      refute Code.ensure_loaded?(module), "#{inspect(module)} is out of scope through VS-01D"
    end
  end

  test "forbidden later-slice boundary paths do not exist through VS-01D" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope through VS-01D"
    end

    assert Path.wildcard("lib/fastcheck/workers/*sales*") == []
  end

  test "existing scanner, mobile, event, attendee, Tickera, and Android surfaces remain untouched" do
    changed_files =
      System.cmd("git", ["diff", "--name-only", "main...HEAD"])
      |> elem(0)
      |> String.split("\n", trim: true)

    forbidden_changed_prefixes = [
      "android/",
      "lib/fastcheck/ticketing/",
      "lib/fastcheck_web/controllers/",
      "lib/fastcheck_web/live/",
      "lib/fastcheck_web/router.ex"
    ]

    for file <- changed_files,
        prefix <- forbidden_changed_prefixes,
        FastCheck.Sales.BoundaryAllowlist.reject_forbidden_changed_file?(file, prefix) do
      flunk("#{file} must not change in Sales skeleton slices through VS-01D")
    end
  end
end
