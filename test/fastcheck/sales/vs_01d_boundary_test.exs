defmodule FastCheck.Sales.Vs01dBoundaryTest do
  use ExUnit.Case, async: true

  @forbidden_resource_modules [
    FastCheck.Sales.Conversation
  ]

  @forbidden_paths [
    "lib/fastcheck/sales/conversation.ex",
    "lib/fastcheck/sales/inventory/reservation_ledger.ex",
    "lib/fastcheck/payments/paystack/client.ex",
    "lib/fastcheck/tickets/issuer.ex",
    "lib/fastcheck/workers/paystack_webhook_worker.ex",
    "lib/fastcheck/workers/verify_payment_worker.ex",
    "lib/fastcheck/workers/delivery_attempt_worker.ex",
    "lib/fastcheck_web/controllers/webhooks/paystack_controller.ex",
    "lib/fastcheck_web/live/sales"
  ]

  @forbidden_action_modules [
    {FastCheck.Sales.TicketIssue, :issue_ticket},
    {FastCheck.Sales.TicketIssue, :mark_issued},
    {FastCheck.Sales.TicketIssue, :revoke_ticket},
    {FastCheck.Sales.DeliveryAttempt, :send_whatsapp},
    {FastCheck.Sales.DeliveryAttempt, :mark_sent},
    {FastCheck.Sales.DeliveryAttempt, :create_queued}
  ]

  test "later Sales resources remain absent in VS-01D" do
    for module <- @forbidden_resource_modules do
      refute Code.ensure_loaded?(module), "#{inspect(module)} is out of scope for VS-01D"
    end
  end

  test "forbidden runtime paths remain absent in VS-01D" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for VS-01D"
    end

    assert Path.wildcard("lib/fastcheck/workers/*delivery*") == []
    assert Path.wildcard("lib/fastcheck/messaging/whatsapp/*") == []
  end

  test "forbidden workflow actions are not implemented in VS-01D" do
    for {resource, action_name} <- @forbidden_action_modules do
      refute Ash.Resource.Info.action(resource, action_name),
             "#{inspect(resource)} must not expose #{inspect(action_name)} in VS-01D"
    end
  end
end
