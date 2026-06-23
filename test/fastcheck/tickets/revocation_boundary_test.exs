defmodule FastCheck.Tickets.RevocationBoundaryTest do
  use ExUnit.Case, async: true

  @revocation_path "lib/fastcheck/tickets/revocation.ex"
  @scanner_visibility_path "lib/fastcheck/tickets/scanner_visibility.ex"
  @revocation_source File.read!(@revocation_path)
  @scanner_visibility_source File.read!(@scanner_visibility_path)

  @forbidden_terms ~w(
    Paystack
    DeliveryAttempt
    WhatsApp
    Redix
    Oban
    RevokeTicketWorker
    mark_refunded
  )

  test "VS-15A revocation entrypoints exist" do
    assert File.exists?(@revocation_path)
    assert File.exists?(@scanner_visibility_path)
    assert Code.ensure_loaded?(FastCheck.Tickets.Revocation)
    assert Code.ensure_loaded?(FastCheck.Tickets.ScannerVisibility)
    assert function_exported?(FastCheck.Tickets.Revocation, :revoke_ticket_issue, 2)
    assert function_exported?(FastCheck.Tickets.Revocation, :revoke_order_tickets, 2)
  end

  test "revocation modules do not reference forbidden later-slice APIs" do
    for source <- [@revocation_source, @scanner_visibility_source],
        term <- @forbidden_terms do
      refute String.contains?(source, term), "must not reference #{term}"
    end
  end
end
