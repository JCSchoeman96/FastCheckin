defmodule FastCheck.Messaging.WhatsApp.DedupeTest do
  use ExUnit.Case, async: false

  alias FastCheck.Messaging.WhatsApp.Dedupe
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport

  setup do
    WebhookTestSupport.flush_redis_keys!()
    on_exit(fn -> WebhookTestSupport.flush_redis_keys!() end)
    :ok
  end

  test "claim_message/2 uses Redis SET NX EX semantics" do
    message_id = "wamid.dedupe-#{System.unique_integer([:positive])}"

    assert {:ok, :new} = Dedupe.claim_message(message_id, 86_400)
    assert {:ok, :duplicate} = Dedupe.claim_message(message_id, 86_400)

    assert {:ok, ttl} =
             Redix.command(FastCheck.Redix, [
               "TTL",
               "fastcheck:whatsapp:dedupe:message:#{message_id}"
             ])

    assert ttl > 0
  end

  test "release_message/1 allows retry after post-dedupe failures" do
    message_id = "wamid.release-#{System.unique_integer([:positive])}"

    assert {:ok, :new} = Dedupe.claim_message(message_id, 86_400)
    assert :ok = Dedupe.release_message(message_id)
    assert {:ok, :new} = Dedupe.claim_message(message_id, 86_400)
  end

  test "claim_message/2 fails closed when Redis process is unavailable" do
    assert {:error, :redis_unavailable} =
             Dedupe.claim_message("wamid.redis-down", 86_400, FastCheck.MissingRedix)
  end
end
