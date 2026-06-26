defmodule FastCheck.Messaging.WhatsApp.InboundNormalizerTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.InboundNormalizer
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport

  test "normalizes a Meta text message into a bounded command" do
    raw_body =
      WebhookTestSupport.text_body(
        provider_message_id: "wamid.text-1",
        phone_e164: "+27821234567",
        text: "2"
      )

    payload = Jason.decode!(raw_body)
    raw_payload_hash = :crypto.hash(:sha256, raw_body) |> Base.encode16(case: :lower)

    assert {:ok, [%MessageCommand{} = command]} =
             InboundNormalizer.normalize(payload,
               raw_payload_hash: raw_payload_hash,
               correlation_id: "corr-1"
             )

    assert command.provider == "meta"
    assert command.provider_message_id == "wamid.text-1"
    assert command.phone_e164 == "+27821234567"
    assert command.wa_id == "27821234567"
    assert command.message_type == "text"
    assert command.text_body == "2"
    assert command.raw_payload_hash == raw_payload_hash
    assert command.correlation_id == "corr-1"
  end

  test "unsupported message types are safe no-ops" do
    raw_body = WebhookTestSupport.unsupported_body(provider_message_id: "wamid.image-1")
    payload = Jason.decode!(raw_body)

    assert {:ok, []} =
             InboundNormalizer.normalize(payload,
               raw_payload_hash: "hash-1",
               correlation_id: "corr-2"
             )
  end

  test "status-only payloads are safe no-ops" do
    payload = WebhookTestSupport.status_body() |> Jason.decode!()
    assert {:ok, []} = InboundNormalizer.normalize(payload, raw_payload_hash: "hash")
  end

  test "message command inspect does not expose PII or full body" do
    command = %MessageCommand{
      provider: "meta",
      provider_message_id: "wamid.secret",
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      message_type: "text",
      text_body: "full private body",
      received_at: DateTime.utc_now(),
      raw_payload_hash: "hash",
      correlation_id: "corr",
      metadata: %{}
    }

    inspected = inspect(command)
    refute inspected =~ "+27821234567"
    refute inspected =~ "27821234567"
    refute inspected =~ "full private body"
    assert inspected =~ "message_type"
  end
end
