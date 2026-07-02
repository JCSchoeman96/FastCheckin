defmodule FastCheck.Messaging.WhatsApp.SessionStoreTest do
  use ExUnit.Case, async: false

  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.SessionStore
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport

  setup do
    WebhookTestSupport.flush_redis_keys!()
    on_exit(fn -> WebhookTestSupport.flush_redis_keys!() end)
    :ok
  end

  test "stores bounded WhatsApp session fields with TTL" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    command = %MessageCommand{
      provider: "meta",
      provider_message_id: "wamid.session-1",
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      message_type: "text",
      text_body: "private body must not be stored",
      received_at: now,
      raw_payload_hash: "hash-session",
      correlation_id: "corr-session",
      metadata: %{}
    }

    conversation = %{
      id: 123,
      state: "new",
      preferred_language: "af",
      expires_at: DateTime.add(now, 86_400, :second),
      needs_human: false,
      handoff_reason: nil
    }

    assert :ok = SessionStore.put_session(command, conversation, 86_400)

    key = SessionStore.key_for_wa_id("27821234567")
    assert {:ok, values} = Redix.command(FastCheck.Redix, ["HGETALL", key])
    session = values |> Enum.chunk_every(2) |> Map.new(fn [k, v] -> {k, v} end)

    assert session["wa_id_hash"]
    assert session["phone_e164_redacted"] == "+27***4567"
    assert session["conversation_id"] == "123"
    assert session["state"] == "new"
    assert session["preferred_language"] == "af"
    assert session["last_provider_message_id"] == "wamid.session-1"
    refute Map.has_key?(session, "raw_payload")
    refute Map.has_key?(session, "text_body")
    refute Map.has_key?(session, "wa_id")
    refute Map.has_key?(session, "phone_e164")
    refute inspect(session) =~ "private body"
    refute inspect(session) =~ "27821234567"
    refute inspect(session) =~ "+27821234567"

    assert {:ok, ttl} = Redix.command(FastCheck.Redix, ["TTL", key])
    assert ttl > 0
  end

  test "updates bounded flow session fields without storing buyer PII" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    command = %MessageCommand{
      provider: "meta",
      provider_message_id: "wamid.session-2",
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      message_type: "text",
      text_body: "Jan Buyer",
      received_at: now,
      raw_payload_hash: "hash-session-2",
      correlation_id: "corr-session-2",
      metadata: %{}
    }

    conversation = %{
      id: 456,
      state: "collecting_email",
      preferred_language: "af",
      expires_at: DateTime.add(now, 86_400, :second),
      needs_human: false,
      handoff_reason: nil
    }

    flow_fields = %{
      selected_event_id: 101,
      selected_offer_id: 202,
      quantity: 2,
      version: 3,
      buyer_name: "Jan Buyer",
      buyer_email: "jan@example.com"
    }

    assert :ok = SessionStore.put_flow_session(command, conversation, flow_fields, 86_400)

    key = SessionStore.key_for_wa_id("27821234567")
    assert {:ok, session} = SessionStore.get_session_by_wa_id("27821234567")

    assert session["conversation_id"] == "456"
    assert session["state"] == "collecting_email"
    assert session["selected_event_id"] == "101"
    assert session["selected_offer_id"] == "202"
    assert session["quantity"] == "2"
    assert session["version"] == "3"
    refute Map.has_key?(session, "buyer_name")
    refute Map.has_key?(session, "buyer_email")
    refute inspect(session) =~ "Jan Buyer"
    refute inspect(session) =~ "jan@example.com"
    refute inspect(session) =~ "27821234567"
    assert {:ok, ttl} = Redix.command(FastCheck.Redix, ["TTL", key])
    assert ttl > 0
  end

  test "does not store resend PII or challenge identifiers in flow session fields" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    command = %MessageCommand{
      provider: "meta",
      provider_message_id: "wamid.session-resend",
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      message_type: "text",
      text_body: "123456",
      received_at: now,
      raw_payload_hash: "hash-session-resend",
      correlation_id: "corr-session-resend",
      metadata: %{}
    }

    conversation = %{
      id: 789,
      state: "collecting_resend_otp",
      preferred_language: "af",
      expires_at: DateTime.add(now, 86_400, :second),
      needs_human: false,
      handoff_reason: nil
    }

    flow_fields = %{
      resend_name: "jamie smith",
      resend_email: "jamie@example.com",
      resend_challenge_public_id: "challenge-public-test",
      resend_otp_verified_at: "2026-07-02T12:00:00Z",
      resend_otp_verification_status: "verified",
      otp: "123456",
      ticket_url: "https://tickets.example/test",
      delivery_token: "secret-token"
    }

    assert :ok = SessionStore.put_flow_session(command, conversation, flow_fields, 86_400)
    assert {:ok, session} = SessionStore.get_session_by_wa_id("27821234567")

    assert session["state"] == "collecting_resend_otp"
    refute Map.has_key?(session, "resend_name")
    refute Map.has_key?(session, "resend_email")
    refute Map.has_key?(session, "resend_challenge_public_id")
    refute Map.has_key?(session, "resend_otp_verified_at")
    refute Map.has_key?(session, "resend_otp_verification_status")
    refute Map.has_key?(session, "otp")
    refute Map.has_key?(session, "ticket_url")
    refute Map.has_key?(session, "delivery_token")
    refute inspect(session) =~ "jamie smith"
    refute inspect(session) =~ "jamie@example.com"
    refute inspect(session) =~ "challenge-public-test"
    refute inspect(session) =~ "123456"
    refute inspect(session) =~ "secret-token"
  end
end
