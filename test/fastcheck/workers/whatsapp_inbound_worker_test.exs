defmodule FastCheck.Workers.WhatsAppInboundWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import ExUnit.CaptureLog

  alias FastCheck.Workers.WhatsAppInboundWorker

  test "worker loads fresh conversation and emits only approved WhatsApp telemetry" do
    conversation_id = insert_conversation!()
    test_pid = self()

    handler = fn event, measurements, metadata, _config ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end

    :telemetry.attach(
      "whatsapp-worker-test-#{System.unique_integer([:positive])}",
      [:fastcheck, :sales, :whatsapp, :inbound_received],
      handler,
      nil
    )

    args = %{
      "provider_message_id" => "wamid.worker-1",
      "wa_id" => "27821234567",
      "phone_e164" => "+27821234567",
      "message_type" => "text",
      "text_body_redacted_or_reference" => "[FILTERED_MESSAGE]",
      "conversation_id" => conversation_id,
      "correlation_id" => "corr-worker",
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "raw_payload_hash" => "hash-worker"
    }

    log =
      capture_log(fn ->
        assert :ok = perform_job(WhatsAppInboundWorker, args)
      end)

    assert_received {:telemetry, [:fastcheck, :sales, :whatsapp, :inbound_received], %{count: 1},
                     metadata}

    assert metadata.conversation_id == conversation_id
    assert metadata.correlation_id == "corr-worker"
    refute log =~ "+27821234567"
    refute log =~ "27821234567"
  after
    :telemetry.detach("whatsapp-worker-test")
  end

  test "new/1 args do not contain full message body" do
    args = %{
      "provider_message_id" => "wamid.worker-2",
      "wa_id" => "27821234567",
      "phone_e164" => "+27821234567",
      "message_type" => "text",
      "text_body" => "secret full body",
      "conversation_id" => 123,
      "correlation_id" => "corr-worker",
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "raw_payload_hash" => "hash-worker"
    }

    assert %Ecto.Changeset{} = changeset = WhatsAppInboundWorker.new(args)
    refute inspect(changeset.changes.args) =~ "secret full body"
    refute inspect(changeset.changes.args) =~ "+27821234567"
    refute inspect(changeset.changes.args) =~ "27821234567"
    refute Map.has_key?(changeset.changes.args, "text_body")
    refute Map.has_key?(changeset.changes.args, "phone_e164")
    refute Map.has_key?(changeset.changes.args, "wa_id")
  end

  defp insert_conversation! do
    %{rows: [[id]]} =
      Repo.query!("""
      INSERT INTO sales_conversations
        (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
      VALUES
        ('+27821234567', '27821234567', 'af', 'new', '{}', false, now(), now())
      RETURNING id
      """)

    id
  end
end
