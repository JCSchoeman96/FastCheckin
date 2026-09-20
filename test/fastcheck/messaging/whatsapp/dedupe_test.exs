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

  test "send_ticket_link duplicate claim scopes the dedupe hold by resend challenge id" do
    conversation_id = 10_001
    ticket_issue_id = 20_001
    challenge_a = 30_001
    challenge_b = 30_002

    ordinary_key =
      "fastcheck:whatsapp:dedupe:send_ticket_link:#{conversation_id}:#{ticket_issue_id}"

    key_a =
      "fastcheck:whatsapp:dedupe:send_ticket_link:" <>
        "#{conversation_id}:#{ticket_issue_id}:challenge:#{challenge_a}"

    key_b =
      "fastcheck:whatsapp:dedupe:send_ticket_link:" <>
        "#{conversation_id}:#{ticket_issue_id}:challenge:#{challenge_b}"

    assert {:ok, :new} =
             Dedupe.claim_send_ticket_link_for_challenge(
               conversation_id,
               ticket_issue_id,
               challenge_a,
               86_400,
               FastCheck.Redix
             )

    assert {:ok, :duplicate} =
             Dedupe.claim_send_ticket_link_for_challenge(
               conversation_id,
               ticket_issue_id,
               challenge_a,
               86_400,
               FastCheck.Redix
             )

    assert {:ok, :new} =
             Dedupe.claim_send_ticket_link_for_challenge(
               conversation_id,
               ticket_issue_id,
               challenge_b,
               86_400,
               FastCheck.Redix
             )

    assert {:ok, :new} = Dedupe.claim_send_ticket_link(conversation_id, ticket_issue_id, 86_400)

    assert {:ok, :duplicate} =
             Dedupe.claim_send_ticket_link(conversation_id, ticket_issue_id, 86_400)

    assert {:ok, ttl} = Redix.command(FastCheck.Redix, ["TTL", ordinary_key])
    assert ttl > 0

    assert {:ok, ttl} = Redix.command(FastCheck.Redix, ["TTL", key_a])
    assert ttl > 0

    assert {:ok, ttl} = Redix.command(FastCheck.Redix, ["TTL", key_b])
    assert ttl > 0
  end

  test "send_ticket_link release only frees the released resend challenge key" do
    conversation_id = 10_002
    ticket_issue_id = 20_002
    challenge_a = 30_003
    challenge_b = 30_004

    assert {:ok, :new} =
             Dedupe.claim_send_ticket_link_for_challenge(
               conversation_id,
               ticket_issue_id,
               challenge_a,
               86_400,
               FastCheck.Redix
             )

    assert {:ok, :new} =
             Dedupe.claim_send_ticket_link_for_challenge(
               conversation_id,
               ticket_issue_id,
               challenge_b,
               86_400,
               FastCheck.Redix
             )

    assert :ok =
             Dedupe.release_send_ticket_link_for_challenge(
               conversation_id,
               ticket_issue_id,
               challenge_a,
               FastCheck.Redix
             )

    assert {:ok, :new} =
             Dedupe.claim_send_ticket_link_for_challenge(
               conversation_id,
               ticket_issue_id,
               challenge_a,
               86_400,
               FastCheck.Redix
             )

    assert {:ok, :duplicate} =
             Dedupe.claim_send_ticket_link_for_challenge(
               conversation_id,
               ticket_issue_id,
               challenge_b,
               86_400,
               FastCheck.Redix
             )
  end
end
