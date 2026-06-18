defmodule FastCheck.Tickets.TicketTokenBoundaryTest do
  use ExUnit.Case, async: true

  @forbidden_paths [
    "lib/fastcheck/tickets/issuer.ex",
    "lib/fastcheck/workers/issue_tickets_worker.ex",
    "lib/fastcheck/workers/send_whatsapp_ticket_worker.ex",
    "lib/fastcheck_web/controllers/ticket_delivery_controller.ex"
  ]

  @allowed_ticket_modules [
    FastCheck.Tickets.CodeGenerator,
    FastCheck.Tickets.TokenHash,
    FastCheck.Tickets.QrPayload,
    FastCheck.Tickets.DeliveryToken
  ]

  test "VS-08 ticket foundation modules exist without issuer" do
    for module <- @allowed_ticket_modules do
      assert Code.ensure_loaded?(module)
    end

    refute Code.ensure_loaded?(FastCheck.Tickets.Issuer)
  end

  test "forbidden issuance and delivery paths remain absent" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for VS-08"
    end
  end

  test "VS-08 does not change scanner, mobile, attendee, or Android surfaces" do
    changed_files =
      System.cmd("git", ["diff", "--name-only", "main...HEAD"])
      |> elem(0)
      |> String.split("\n", trim: true)

    forbidden_changed_prefixes = [
      "android/",
      "lib/fastcheck/attendees/",
      "lib/fastcheck_web/controllers/mobile/",
      "lib/fastcheck_web/live/scanner",
      "lib/fastcheck_web/router.ex"
    ]

    for file <- changed_files, prefix <- forbidden_changed_prefixes do
      assert not String.starts_with?(file, prefix),
             "#{file} must not change in VS-08"
    end
  end
end
