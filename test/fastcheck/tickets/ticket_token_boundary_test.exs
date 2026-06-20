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

  test "VS-08 ticket foundation modules exist with VS-09A contract issuer stub" do
    for module <- @allowed_ticket_modules do
      assert Code.ensure_loaded?(module)
    end
  end

  test "VS-09A issuer stub is contract-only and raises" do
    assert File.exists?(@issuer_path)
    assert @issuer_source =~ "VS-09A"
    assert @issuer_source =~ "not implemented until VS-09B"
    refute @issuer_source =~ "alias FastCheck.Repo"
    refute @issuer_source =~ "Ash.create"
  end

  test "forbidden issuance and delivery paths remain absent" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for VS-09A contract slice"
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
             "#{file} must not change in VS-08/VS-09A contract work"
    end
  end
end
