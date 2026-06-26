defmodule FastCheck.Workers.WhatsAppInboundWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import ExUnit.CaptureLog

  alias FastCheck.Crypto
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheck.Workers.WhatsAppInboundWorker
  alias FastCheckWeb.SalesWebFixtures

  setup do
    cleanup = WebhookTestSupport.setup_whatsapp!()

    on_exit(fn ->
      cleanup.()
    end)

    :ok
  end

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

  test "worker drives conversation flow using encrypted text and conversation PII" do
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.outbound-1"}]})
       }}
    end)

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Worker Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "Worker General")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    conversation_id = insert_conversation!()
    {:ok, encrypted} = Crypto.encrypt("hi")

    args = %{
      "provider_message_id" => "wamid.worker-flow-1",
      "message_type" => "text",
      "text_body_encrypted" => encrypted,
      "text_body_redacted_or_reference" => "[FILTERED_MESSAGE]",
      "conversation_id" => conversation_id,
      "correlation_id" => "corr-worker-flow",
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "raw_payload_hash" => "hash-worker-flow"
    }

    log =
      capture_log(fn ->
        assert :ok = perform_job(WhatsAppInboundWorker, args)
      end)

    assert_received {:whatsapp_request, request}
    assert request.options.json["to"] == "27821234567"
    assert request.options.json["text"]["body"] =~ "Welkom by FastCheck Tickets"
    refute inspect(args) =~ "hi"
    refute log =~ "+27821234567"
    refute log =~ "27821234567"
    refute log =~ "Welkom by FastCheck Tickets"
  end

  test "retryable outbound failure does not reinterpret the same provider message on retry" do
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 500,
         body: Jason.encode!(%{"error" => %{"message" => "temporary provider failure"}})
       }}
    end)

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Retry Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "Retry General")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    conversation_id = insert_conversation!(state: "selecting_language")
    {:ok, encrypted} = Crypto.encrypt("1")

    args = %{
      "provider_message_id" => "wamid.worker-retry-1",
      "message_type" => "text",
      "text_body_encrypted" => encrypted,
      "text_body_redacted_or_reference" => "[FILTERED_MESSAGE]",
      "conversation_id" => conversation_id,
      "correlation_id" => "corr-worker-retry",
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "raw_payload_hash" => "hash-worker-retry"
    }

    assert {:error, :whatsapp_send_retryable} = perform_job(WhatsAppInboundWorker, args)
    assert_received {:whatsapp_request, _request}
    assert conversation_state(conversation_id) == "main_menu"

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:unexpected_retry_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.outbound-retry"}]})
       }}
    end)

    assert :ok = perform_job(WhatsAppInboundWorker, args)
    refute_received {:unexpected_retry_request, _request}
    assert conversation_state(conversation_id) == "main_menu"
  end

  defp insert_conversation!(opts \\ []) do
    state = Keyword.get(opts, :state, "new")

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES
          ('+27821234567', '27821234567', 'af', $1, '{}', false, now(), now())
        RETURNING id
        """,
        [state]
      )

    id
  end

  defp conversation_state(conversation_id) do
    %{rows: [[state]]} =
      Repo.query!("SELECT state FROM sales_conversations WHERE id = $1", [conversation_id])

    state
  end

  defp scanner_code do
    System.unique_integer([:positive])
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
