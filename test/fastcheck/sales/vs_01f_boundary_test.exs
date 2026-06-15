defmodule FastCheck.Sales.Vs01fBoundaryTest do
  use ExUnit.Case, async: true

  @forbidden_paths [
    "lib/fastcheck/sales/inventory",
    "lib/fastcheck/payments/paystack",
    "lib/fastcheck/messaging/whatsapp",
    "lib/fastcheck/tickets/issuer.ex",
    "lib/fastcheck/tickets/code_generator.ex",
    "lib/fastcheck/tickets/qr_payload.ex",
    "lib/fastcheck/tickets/delivery_token.ex",
    "lib/fastcheck/workers",
    "lib/fastcheck_web/controllers/webhooks",
    "lib/fastcheck_web/controllers/ticket_delivery_controller.ex",
    "lib/fastcheck_web/live/sales"
  ]

  @resources [
    FastCheck.Sales.TicketOffer,
    FastCheck.Sales.Order,
    FastCheck.Sales.OrderLine,
    FastCheck.Sales.StateTransition,
    FastCheck.Sales.CheckoutSession,
    FastCheck.Sales.PaymentAttempt,
    FastCheck.Sales.PaymentEvent,
    FastCheck.Sales.TicketIssue,
    FastCheck.Sales.DeliveryAttempt,
    FastCheck.Sales.Conversation
  ]

  @forbidden_action_names [
    :create,
    :update,
    :destroy,
    :upsert,
    :update_status,
    :update_state,
    :record_transition,
    :create_session,
    :attach_inventory_hold,
    :mark_payment_link_sent,
    :store_webhook_event,
    :mark_verified_success,
    :issue_ticket,
    :revoke_ticket,
    :send_whatsapp,
    :start_or_resume,
    :confirm_order
  ]

  test "forbidden runtime paths remain absent in VS-01F" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for VS-01F"
    end

    assert Path.wildcard("lib/fastcheck/sales/inventory/*") == []
    assert Path.wildcard("lib/fastcheck/payments/paystack/*") == []
    assert Path.wildcard("lib/fastcheck/messaging/whatsapp/*") == []
    assert Path.wildcard("lib/fastcheck/workers/*") == []
  end

  test "VS-01F does not add workflow or generic status actions" do
    for resource <- @resources, action_name <- @forbidden_action_names do
      refute Ash.Resource.Info.action(resource, action_name),
             "#{inspect(resource)} must not expose #{inspect(action_name)} in VS-01F"
    end
  end

  test "VS-01F does not introduce organization tenancy fields" do
    for resource <- @resources do
      refute Ash.Resource.Info.attribute(resource, :organization_id),
             "#{inspect(resource)} must not define organization_id in VS-01F"
    end
  end

  test "existing scanner, mobile, event, attendee, Tickera, and Android surfaces remain untouched" do
    changed_files =
      System.cmd("git", ["diff", "--name-only", "main...HEAD"])
      |> elem(0)
      |> String.split("\n", trim: true)

    forbidden_changed_prefixes = [
      "android/",
      "lib/fastcheck/attendees/",
      "lib/fastcheck/events/",
      "lib/fastcheck/ticketing/",
      "lib/fastcheck/tickera",
      "lib/fastcheck_web/controllers/",
      "lib/fastcheck_web/live/",
      "lib/fastcheck_web/router.ex"
    ]

    for file <- changed_files,
        prefix <- forbidden_changed_prefixes,
        String.starts_with?(file, prefix) do
      flunk("#{file} must not change in VS-01F")
    end
  end
end
