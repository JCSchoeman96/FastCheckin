defmodule FastCheck.Tickets.TicketTokenBoundaryTest do
  use ExUnit.Case, async: true

  @issuer_path "lib/fastcheck/tickets/issuer.ex"
  @issuer_source File.read!("lib/fastcheck/tickets/issuer.ex")

  @forbidden_paths [
    "lib/fastcheck/workers/issue_tickets_worker.ex",
    "lib/fastcheck/workers/send_whatsapp_ticket_worker.ex",
    "lib/fastcheck_web/controllers/ticket_delivery_controller.ex"
  ]

  @allowed_ticket_modules [
    FastCheck.Tickets.CodeGenerator,
    FastCheck.Tickets.TokenHash,
    FastCheck.Tickets.QrPayload,
    FastCheck.Tickets.DeliveryToken,
    FastCheck.Tickets.Issuer
  ]

  test "VS-08 ticket foundation modules exist with VS-09B attendee bridge issuer" do
    for module <- @allowed_ticket_modules do
      assert Code.ensure_loaded?(module)
    end
  end

  test "VS-09B issuer implements attendee bridge without TicketIssue or delivery behavior" do
    assert File.exists?(@issuer_path)
    assert @issuer_source =~ "VS-09B implements the Attendee creation bridge only"
    assert @issuer_source =~ ":attendees_ready"
    refute @issuer_source =~ "alias FastCheck.Sales.TicketIssue"
    refute @issuer_source =~ "Ash.create"
    refute @issuer_source =~ "DeliveryToken"
  end

  test "forbidden issuance and delivery paths remain absent" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for VS-09B attendee bridge"
    end
  end

  test "VS-09B does not change scanner, mobile controller, or Android surfaces" do
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

    for file <- changed_files, prefix <- forbidden_changed_prefixes do
      assert not String.starts_with?(file, prefix),
             "#{file} must not change in VS-09B attendee bridge work"
    end
  end
end
