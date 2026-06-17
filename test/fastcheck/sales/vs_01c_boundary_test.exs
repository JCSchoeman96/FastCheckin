defmodule FastCheck.Sales.Vs01cBoundaryTest do
  use ExUnit.Case, async: true

  @forbidden_resource_modules []

  @forbidden_paths [
    "lib/fastcheck/tickets/issuer.ex",
    "lib/fastcheck/workers/paystack_webhook_worker.ex",
    "lib/fastcheck/workers/verify_payment_worker.ex",
    "lib/fastcheck_web/controllers/webhooks/paystack_controller.ex"
  ]

  @forbidden_action_modules [
    {FastCheck.Sales.PaymentAttempt, :create_initialized},
    {FastCheck.Sales.PaymentAttempt, :mark_verified_success},
    {FastCheck.Sales.PaymentEvent, :store_webhook_event},
    {FastCheck.Sales.PaymentEvent, :mark_processed}
  ]

  test "later Sales resources remain absent in VS-01C" do
    for module <- @forbidden_resource_modules do
      refute Code.ensure_loaded?(module), "#{inspect(module)} is out of scope for VS-01C"
    end
  end

  test "forbidden runtime paths remain absent in VS-01C" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for VS-01C"
    end

    assert Path.wildcard("lib/fastcheck/workers/*paystack*") == []
    assert Path.wildcard("lib/fastcheck/workers/*payment*") == []
  end

  test "forbidden workflow actions are not implemented in VS-01C" do
    for {resource, action_name} <- @forbidden_action_modules do
      refute Ash.Resource.Info.action(resource, action_name),
             "#{inspect(resource)} must not expose #{inspect(action_name)} in VS-01C"
    end
  end
end
