defmodule FastCheck.Messaging.WhatsApp.InboundCheckpointTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Messaging.WhatsApp.InboundCheckpoint
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Sales.Conversation

  test "creates a durable Conversation checkpoint for first inbound message" do
    command = command("wamid.first")

    assert {:ok, %Conversation{} = conversation} = InboundCheckpoint.checkpoint(command, 86_400)
    assert conversation.phone_e164 == "+27821234567"
    assert conversation.wa_id == "27821234567"
    assert conversation.state == "new"
    assert conversation.preferred_language == "af"
    assert conversation.last_inbound_message_id == "wamid.first"
    assert conversation.last_message_at == command.received_at
    assert conversation.expires_at
  end

  test "resumes existing checkpoint instead of creating another row" do
    assert {:ok, first} = InboundCheckpoint.checkpoint(command("wamid.one"), 86_400)
    assert {:ok, second} = InboundCheckpoint.checkpoint(command("wamid.two"), 86_400)

    assert second.id == first.id
    assert second.last_inbound_message_id == "wamid.two"
    assert count_conversations() == 1
  end

  defp command(message_id) do
    %MessageCommand{
      provider: "meta",
      provider_message_id: message_id,
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      message_type: "text",
      text_body: "2",
      received_at: DateTime.utc_now() |> DateTime.truncate(:second),
      raw_payload_hash: "hash-#{message_id}",
      correlation_id: "corr-#{message_id}",
      metadata: %{}
    }
  end

  defp count_conversations do
    %{rows: [[count]]} = Repo.query!("SELECT count(*)::int FROM sales_conversations")
    count
  end
end
