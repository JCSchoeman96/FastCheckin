defmodule FastCheck.Sales.Vs01fBoundaryTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo

  @forbidden_paths [
    "lib/fastcheck_web/controllers/ticket_delivery_controller.ex"
  ]

  @resources [
    FastCheck.Sales.TicketOffer,
    FastCheck.Sales.Order,
    FastCheck.Sales.OrderLine,
    FastCheck.Sales.StateTransition,
    FastCheck.Sales.CheckoutSession,
    FastCheck.Sales.PaymentAttempt,
    FastCheck.Sales.PaymentEvent,
    FastCheck.Sales.ManualReviewAction,
    FastCheck.Sales.TicketIssue,
    FastCheck.Sales.DeliveryAttempt,
    FastCheck.Sales.Conversation
  ]

  @forbidden_action_names_by_resource %{
    FastCheck.Sales.PaymentAttempt => [
      :create_initialized,
      :mark_webhook_received
    ],
    FastCheck.Sales.PaymentEvent => [],
    FastCheck.Sales.TicketIssue => [
      :issue_ticket,
      :revoke_ticket
    ],
    FastCheck.Sales.Conversation => [
      :send_whatsapp,
      :start_or_resume
    ]
  }

  @global_forbidden_action_names [
    :upsert,
    :update_status,
    :update_state,
    :confirm_order
  ]

  test "forbidden runtime paths remain absent in VS-01F" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for VS-01F"
    end

    assert Path.wildcard("lib/fastcheck/workers/*") |> Enum.sort() == [
             "lib/fastcheck/workers/checkout_expiry_sweeper_worker.ex",
             "lib/fastcheck/workers/checkout_expiry_worker.ex",
             "lib/fastcheck/workers/issue_tickets_worker.ex",
             "lib/fastcheck/workers/send_whatsapp_payment_link_worker.ex",
             "lib/fastcheck/workers/send_whatsapp_ticket_link_worker.ex",
             "lib/fastcheck/workers/whatsapp_inbound_worker.ex"
           ]
  end

  test "VS-01F does not add workflow or generic status actions" do
    for resource <- @resources,
        action_name <- @global_forbidden_action_names,
        not (resource == FastCheck.Sales.Conversation and action_name == :confirm_order) do
      refute ResourceInfo.action(resource, action_name),
             "#{inspect(resource)} must not expose #{inspect(action_name)}"
    end

    for {resource, forbidden_names} <- @forbidden_action_names_by_resource,
        action_name <- forbidden_names do
      refute ResourceInfo.action(resource, action_name),
             "#{inspect(resource)} must not expose #{inspect(action_name)}"
    end
  end

  test "VS-01F does not introduce organization tenancy fields" do
    for resource <- @resources do
      refute ResourceInfo.attribute(resource, :organization_id),
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
      "lib/fastcheck/ticketing/",
      "lib/fastcheck_web/controllers/",
      "lib/fastcheck_web/live/",
      "lib/fastcheck_web/router.ex"
    ]

    for file <- changed_files,
        prefix <- forbidden_changed_prefixes,
        FastCheck.Sales.BoundaryAllowlist.reject_forbidden_changed_file?(file, prefix) do
      flunk("#{file} must not change in VS-01F")
    end
  end
end
