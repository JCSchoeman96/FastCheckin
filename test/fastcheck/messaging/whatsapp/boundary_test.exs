defmodule FastCheck.Messaging.WhatsApp.BoundaryTest do
  use ExUnit.Case, async: true

  @whatsapp_modules [
    "lib/fastcheck/messaging/whatsapp/config.ex",
    "lib/fastcheck/messaging/whatsapp/client.ex",
    "lib/fastcheck/messaging/whatsapp/message_builder.ex",
    "lib/fastcheck/messaging/whatsapp/template_catalog.ex",
    "lib/fastcheck/messaging/whatsapp/response.ex"
  ]

  @forbidden_tokens [
    "FastCheck.Sales",
    "Ash.",
    "FastCheck.Repo",
    "Oban",
    "Redix",
    "Redis",
    "Cachex",
    "PubSub",
    "ReservationLedger",
    "TicketIssue",
    "Attendee",
    "FastCheckWeb.Router",
    "FastCheckWeb.Controller",
    "FastCheckWeb.Live",
    "FastCheckWeb.Endpoint",
    "FastCheck.Scans",
    "FastCheck.Attendees",
    "FastCheck.Tickets",
    "FastCheck.Payments",
    "FastCheck.Checkout"
  ]

  @vs_18_conversation_modules [
    "lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex",
    "lib/fastcheck/messaging/whatsapp/input_normalizer.ex",
    "lib/fastcheck/messaging/whatsapp/menu_renderer.ex",
    "lib/fastcheck/messaging/whatsapp/copy.ex",
    "lib/fastcheck/messaging/whatsapp/flow_result.ex"
  ]

  @vs_18_forbidden_tokens [
    "FastCheck.Payments",
    "TransactionInitialization",
    "Paystack",
    "TicketIssue",
    "DeliveryAttempt",
    "FastCheck.Attendees",
    "FastCheck.Scans",
    "FastCheckWeb.Router",
    "FastCheckWeb.Live",
    "android/scanner-app"
  ]

  test "vs-16 whatsapp provider modules exist in provider boundary namespace" do
    for path <- @whatsapp_modules do
      assert File.exists?(path), "expected #{path}"
    end
  end

  test "whatsapp provider modules do not couple to sales, persistence, workers, or web surfaces" do
    for file <- @whatsapp_modules do
      body = File.read!(file)

      for token <- @forbidden_tokens do
        refute String.contains?(body, token), "#{file} must not reference #{token}"
      end
    end
  end

  test "vs-17 adds only approved inbound webhook and worker paths" do
    assert File.exists?("lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex")
    assert File.exists?("lib/fastcheck/workers/whatsapp_inbound_worker.ex")
    refute File.exists?("lib/fastcheck/workers/send_whatsapp_ticket_worker.ex")
    assert Path.wildcard("android/scanner-app/**/*") != []
  end

  test "vs-18 conversation modules do not own payment, ticket, delivery, scanner, or mobile behavior" do
    for file <- @vs_18_conversation_modules do
      assert File.exists?(file), "expected #{file}"
      body = File.read!(file)

      for token <- @vs_18_forbidden_tokens do
        refute String.contains?(body, token), "#{file} must not reference #{token}"
      end
    end
  end
end
