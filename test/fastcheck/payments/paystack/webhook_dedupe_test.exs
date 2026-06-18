defmodule FastCheck.Payments.Paystack.WebhookDedupeTest do
  use ExUnit.Case, async: false

  alias FastCheck.Payments.Paystack.EventDedupe
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport

  setup do
    PaystackSupport.flush_webhook_dedupe_keys!()
    on_exit(fn -> PaystackSupport.flush_webhook_dedupe_keys!() end)
    :ok
  end

  test "claim uses provider_event_id as dedupe key when present" do
    key = "evt-#{System.unique_integer([:positive])}"
    assert :ok = EventDedupe.claim(key)
    assert {:error, :duplicate} = EventDedupe.claim(key)
  end

  test "dedupe_key falls back to payload_hash when provider_event_id is absent" do
    assert EventDedupe.dedupe_key(nil, "hash-abc") == "hash-abc"
    assert EventDedupe.dedupe_key("evt-1", "hash-abc") == "evt-1"
  end
end
