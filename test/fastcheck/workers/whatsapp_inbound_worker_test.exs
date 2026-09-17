defmodule FastCheck.Workers.WhatsAppInboundWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import ExUnit.CaptureLog
  require Ash.Query

  alias Ash.Changeset
  alias Ash.Error.Invalid
  alias Ash.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias FastCheck.Crypto
  alias FastCheck.Messaging.WhatsApp.InboundCheckpoint
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.Payments.TestSupport, as: PaymentSupport
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheck.SalesE2EFixtures
  alias FastCheck.Workers.WhatsAppInboundWorker
  alias FastCheckWeb.SalesWebFixtures

  @unsafe_sentinels [
    "CUSTOMER_BODY_SENTINEL",
    "+27829990001",
    "27829990001",
    "EAAG_ACCESS_TOKEN_SENTINEL",
    "https://checkout.paystack.test/payment/SENTINEL",
    "https://tickets.fastcheck.test/ticket/SENTINEL",
    "OTP-654321-SENTINEL",
    ~s({"raw":"META_PAYLOAD_SENTINEL"}),
    "META_PROVIDER_ERROR_SENTINEL"
  ]

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

  test "new/1 args do not contain plaintext sensitive values" do
    args = %{
      "provider_message_id" => "wamid.worker-2",
      "wa_id" => "27821234567",
      "phone_e164" => "+27821234567",
      "message_type" => "text",
      "text_body" => Enum.join(@unsafe_sentinels, "|"),
      "conversation_id" => 123,
      "correlation_id" => "corr-worker",
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "raw_payload_hash" => "hash-worker"
    }

    assert %Ecto.Changeset{} = changeset = WhatsAppInboundWorker.new(args)
    args_output = inspect(changeset.changes.args)

    for sentinel <- @unsafe_sentinels do
      refute args_output =~ sentinel
    end

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
    raw_body_marker = "<RAW_WHATSAPP_BODY:secret-marker>"
    {:ok, encrypted} = Crypto.encrypt(raw_body_marker)

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
    assert args["text_body_encrypted"] == encrypted
    refute args["text_body_encrypted"] == raw_body_marker
    refute Map.has_key?(args, "text_body")
    refute log =~ raw_body_marker
    refute log =~ "+27821234567"
    refute log =~ "27821234567"
    refute log =~ "Welkom by FastCheck Tickets"
  end

  test "duplicate worker execution does not send duplicate WhatsApp replies" do
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.outbound-duplicate"}]})
       }}
    end)

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Duplicate Worker Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "Duplicate General")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    conversation_id = insert_conversation!()
    {:ok, encrypted} = Crypto.encrypt("hi")

    args = %{
      "provider_message_id" => "wamid.worker-duplicate-1",
      "message_type" => "text",
      "text_body_encrypted" => encrypted,
      "text_body_redacted_or_reference" => "[FILTERED_MESSAGE]",
      "conversation_id" => conversation_id,
      "correlation_id" => "corr-worker-duplicate",
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "raw_payload_hash" => "hash-worker-duplicate"
    }

    assert :ok = perform_job(WhatsAppInboundWorker, args)
    assert_received {:whatsapp_request, request}
    assert request.options.json["text"]["body"] =~ "Welkom by FastCheck Tickets"

    assert :ok = perform_job(WhatsAppInboundWorker, args)
    refute_received {:whatsapp_request, _request}

    assert conversation_state(conversation_id) == "selecting_language"

    {state_data, needs_human, handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["last_handled_inbound_message_id"] == args["provider_message_id"]
    assert state_data["pending_reply"]["status"] == "reply_sent"
    assert is_nil(state_data["pending_reply"]["ciphertext"])
    refute needs_human
    assert is_nil(handoff_reason)
  end

  test "retryable outbound failure sends the durable exact reply on retry without replaying business transition" do
    test_pid = self()
    counter = :counters.new(1, [])

    Application.put_env(
      :fastcheck,
      :whatsapp_request_fun,
      retryable_then_success_request_fun(test_pid, counter, "wamid.outbound-retry")
    )

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

    first_log =
      capture_log(fn ->
        assert {:error, :whatsapp_send_retryable} = perform_job(WhatsAppInboundWorker, args)
      end)

    assert_received {:whatsapp_request, 1, first_request}
    expected_body = first_request.options.json["text"]["body"]
    assert :counters.get(counter, 1) == 1
    assert conversation_state(conversation_id) == "main_menu"

    {state_data, needs_human, handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["last_handled_inbound_message_id"] == args["provider_message_id"]
    assert state_data["pending_reply"]["status"] == "reply_retryable"
    assert state_data["pending_reply"]["provider_message_id"] == args["provider_message_id"]
    assert {:ok, ^expected_body} = Crypto.decrypt(state_data["pending_reply"]["ciphertext"])
    assert state_data["pending_reply"]["attempt_count"] == 1
    refute needs_human
    assert is_nil(handoff_reason)

    refute inspect(WhatsAppInboundWorker.new(args).changes.args) =~ expected_body

    second_log = capture_log(fn -> assert :ok = perform_job(WhatsAppInboundWorker, args) end)

    assert_received {:whatsapp_request, 2, second_request}
    assert second_request.options.json["text"]["body"] == expected_body
    assert :counters.get(counter, 1) == 2
    assert conversation_state(conversation_id) == "main_menu"
    assert conversation_transition_count(conversation_id) == 1

    {state_data, needs_human, handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["last_handled_inbound_message_id"] == args["provider_message_id"]
    assert state_data["pending_reply"]["status"] == "reply_sent"
    assert is_nil(state_data["pending_reply"]["ciphertext"])
    assert state_data["pending_reply"]["outbound_message_id"] == "wamid.outbound-retry"
    refute needs_human
    assert is_nil(handoff_reason)

    logs = first_log <> second_log
    refute logs =~ expected_body
    refute logs =~ "+27821234567"
    refute logs =~ "27821234567"
    refute logs =~ "temporary provider failure"
  end

  test "retry sends the pending reply after a fresh Conversation reload" do
    test_pid = self()
    counter = :counters.new(1, [])

    Application.put_env(
      :fastcheck,
      :whatsapp_request_fun,
      retryable_then_success_request_fun(test_pid, counter, "wamid.outbound-reload")
    )

    conversation_id = insert_conversation!(state: "selecting_language")
    {:ok, encrypted} = Crypto.encrypt("1")

    args = inbound_worker_args(conversation_id, "wamid.worker-reload-1", encrypted)

    assert {:error, :whatsapp_send_retryable} = perform_job(WhatsAppInboundWorker, args)
    assert_received {:whatsapp_request, 1, first_request}
    first_body = first_request.options.json["text"]["body"]

    reloaded = reload_conversation!(conversation_id)
    pending_reply = reloaded.state_data["pending_reply"]
    assert pending_reply["status"] == "reply_retryable"
    assert {:ok, persisted_body} = Crypto.decrypt(pending_reply["ciphertext"])
    assert persisted_body == first_body

    assert :ok = perform_job(WhatsAppInboundWorker, args)
    assert_received {:whatsapp_request, 2, second_request}
    assert second_request.options.json["text"]["body"] == persisted_body
    assert :counters.get(counter, 1) == 2
    assert conversation_state(conversation_id) == "main_menu"
    assert conversation_transition_count(conversation_id) == 1
  end

  test "distinct inbound remains outstanding while an earlier reply is retryable" do
    test_pid = self()
    counter = :counters.new(1, [])

    Application.put_env(
      :fastcheck,
      :whatsapp_request_fun,
      retryable_then_success_request_fun(test_pid, counter, "wamid.outbound-distinct")
    )

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Distinct Inbound Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "Distinct General")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    conversation_id = insert_conversation!(state: "selecting_language")
    {:ok, encrypted_a} = Crypto.encrypt("1")
    {:ok, encrypted_b} = Crypto.encrypt("1")
    args_a = inbound_worker_args(conversation_id, "wamid.worker-distinct-a", encrypted_a)
    args_b = inbound_worker_args(conversation_id, "wamid.worker-distinct-b", encrypted_b)

    assert {:ok, _a_job} = WhatsAppInboundWorker.new(args_a) |> Oban.insert()

    assert {:error, :whatsapp_send_retryable} = perform_job(WhatsAppInboundWorker, args_a)
    assert_received {:whatsapp_request, 1, first_request}
    expected_a_body = first_request.options.json["text"]["body"]
    assert conversation_state(conversation_id) == "main_menu"
    assert conversation_transition_count(conversation_id) == 1

    assert {:snooze, snooze_seconds} = perform_job(WhatsAppInboundWorker, args_b)
    assert snooze_seconds > 0
    refute_received {:whatsapp_request, _, _}
    assert conversation_state(conversation_id) == "main_menu"
    assert conversation_transition_count(conversation_id) == 1

    {state_data, _needs_human, _handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["pending_reply"]["provider_message_id"] == args_a["provider_message_id"]
    assert state_data["pending_reply"]["status"] == "reply_retryable"
    assert {:ok, ^expected_a_body} = Crypto.decrypt(state_data["pending_reply"]["ciphertext"])

    assert :ok = perform_job(WhatsAppInboundWorker, args_a)
    assert_received {:whatsapp_request, 2, second_request}
    assert second_request.options.json["text"]["body"] == expected_a_body
    assert conversation_state(conversation_id) == "main_menu"
    assert conversation_transition_count(conversation_id) == 1

    assert :ok = perform_job(WhatsAppInboundWorker, args_b)
    assert_received {:whatsapp_request, 3, third_request}
    refute third_request.options.json["text"]["body"] == expected_a_body
    assert :counters.get(counter, 1) == 3
    assert conversation_state(conversation_id) == "selecting_event"
    assert conversation_transition_count(conversation_id) == 2

    {state_data, _needs_human, _handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["last_handled_inbound_message_id"] == args_b["provider_message_id"]
    assert state_data["pending_reply"]["provider_message_id"] == args_b["provider_message_id"]
    assert state_data["pending_reply"]["status"] == "reply_sent"
    assert is_nil(state_data["pending_reply"]["ciphertext"])
  end

  test "permanent failure of an earlier reply does not discard a distinct inbound" do
    test_pid = self()
    counter = :counters.new(1, [])

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)
      send(test_pid, {:whatsapp_request, attempt, request})

      response =
        case attempt do
          1 ->
            %Req.Response{
              status: 500,
              body: Jason.encode!(%{"error" => %{"message" => "temporary"}})
            }

          2 ->
            %Req.Response{
              status: 400,
              body: Jason.encode!(%{"error" => %{"message" => "invalid"}})
            }

          _ ->
            %Req.Response{
              status: 200,
              body: Jason.encode!(%{"messages" => [%{"id" => "wamid.outbound-after-failure"}]})
            }
        end

      {:ok, response}
    end)

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Permanent Failure Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "Permanent Failure General")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    conversation_id = insert_conversation!(state: "selecting_language")
    {:ok, encrypted_a} = Crypto.encrypt("1")
    {:ok, encrypted_b} = Crypto.encrypt("1")
    args_a = inbound_worker_args(conversation_id, "wamid.worker-permanent-a", encrypted_a)
    args_b = inbound_worker_args(conversation_id, "wamid.worker-permanent-b", encrypted_b)

    assert {:error, :whatsapp_send_retryable} = perform_job(WhatsAppInboundWorker, args_a)
    assert_received {:whatsapp_request, 1, _request}

    assert {:snooze, _snooze_seconds} = perform_job(WhatsAppInboundWorker, args_b)
    refute_received {:whatsapp_request, _, _}

    assert {:discard, :whatsapp_reply_failed} =
             perform_job(build_job(WhatsAppInboundWorker, args_a, attempt: 2))

    assert_received {:whatsapp_request, 2, _request}
    assert conversation_state(conversation_id) == "main_menu"
    assert conversation_transition_count(conversation_id) == 1

    {state_data, needs_human, handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["pending_reply"]["provider_message_id"] == args_a["provider_message_id"]
    assert state_data["pending_reply"]["status"] == "reply_failed"
    assert is_nil(state_data["pending_reply"]["ciphertext"])
    assert needs_human
    assert handoff_reason == "whatsapp_reply_validation_failure"

    assert :ok = perform_job(WhatsAppInboundWorker, args_b)
    assert_received {:whatsapp_request, 3, _request}
    assert conversation_state(conversation_id) == "selecting_event"
    assert conversation_transition_count(conversation_id) == 2

    {state_data, _needs_human, _handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["last_handled_inbound_message_id"] == args_b["provider_message_id"]
    assert state_data["pending_reply"]["provider_message_id"] == args_b["provider_message_id"]
    assert state_data["pending_reply"]["status"] == "reply_sent"
  end

  test "a distinct inbound can recover a pending reply whose Oban job was discarded" do
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.outbound-recovered-b"}]})
       }}
    end)

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Discarded Inbound Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "Discarded General")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    {:ok, encrypted_a} = Crypto.encrypt("reply A")

    conversation_id =
      insert_conversation!(
        state: "main_menu",
        state_data: %{
          "last_handled_inbound_message_id" => "wamid.discarded-a",
          "pending_reply" => %{
            "ciphertext" => encrypted_a,
            "provider_message_id" => "wamid.discarded-a",
            "status" => "reply_retryable",
            "attempt_count" => 1
          }
        }
      )

    {:ok, encrypted_b} = Crypto.encrypt("1")
    args_a = inbound_worker_args(conversation_id, "wamid.discarded-a", encrypted_a)
    args_b = inbound_worker_args(conversation_id, "wamid.discarded-b", encrypted_b)

    assert {:ok, discarded_job} = WhatsAppInboundWorker.new(args_a) |> Oban.insert()

    Repo.query!(
      "UPDATE oban_jobs SET state = 'discarded', discarded_at = now() WHERE id = $1",
      [discarded_job.id]
    )

    assert :ok = perform_job(WhatsAppInboundWorker, args_b)
    assert_received {:whatsapp_request, request}
    assert request.options.json["text"]["body"] =~ "Discarded Inbound Event"
    assert conversation_state(conversation_id) == "selecting_event"
    assert conversation_transition_count(conversation_id) == 1

    {state_data, _needs_human, _handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["last_handled_inbound_message_id"] == args_b["provider_message_id"]
    assert state_data["pending_reply"]["provider_message_id"] == args_b["provider_message_id"]
    assert state_data["pending_reply"]["status"] == "reply_sent"
  end

  test "a distinct inbound can recover a pending reply whose Oban row was pruned" do
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.outbound-pruned-b"}]})
       }}
    end)

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Pruned Inbound Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "Pruned General")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    {:ok, encrypted_a} = Crypto.encrypt("reply A")

    computed_at =
      DateTime.utc_now()
      |> DateTime.add(-8 * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    conversation_id =
      insert_conversation!(
        state: "main_menu",
        state_data: %{
          "last_handled_inbound_message_id" => "wamid.pruned-a",
          "pending_reply" => %{
            "ciphertext" => encrypted_a,
            "provider_message_id" => "wamid.pruned-a",
            "status" => "reply_retryable",
            "attempt_count" => 1,
            "computed_at" => computed_at
          }
        }
      )

    {:ok, encrypted_b} = Crypto.encrypt("1")
    args_b = inbound_worker_args(conversation_id, "wamid.pruned-b", encrypted_b)

    assert :ok = perform_job(WhatsAppInboundWorker, args_b)
    assert_received {:whatsapp_request, request}
    assert request.options.json["text"]["body"] =~ "Pruned Inbound Event"
    assert conversation_state(conversation_id) == "selecting_event"
    assert conversation_transition_count(conversation_id) == 1
  end

  test "concurrent distinct inbound jobs serialize around the pending reply slot" do
    parent = self()
    counter = :counters.new(1, [])

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)
      send(parent, {:whatsapp_request, attempt, request})

      if attempt == 1 do
        receive do
          :release_first_request -> :ok
        end
      end

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.outbound-concurrent-#{attempt}"}]})
       }}
    end)

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Concurrent Inbound Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "Concurrent General")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    conversation_id = insert_conversation!(state: "selecting_language")
    {:ok, encrypted_a} = Crypto.encrypt("1")
    {:ok, encrypted_b} = Crypto.encrypt("1")
    args_a = inbound_worker_args(conversation_id, "wamid.worker-concurrent-a", encrypted_a)
    args_b = inbound_worker_args(conversation_id, "wamid.worker-concurrent-b", encrypted_b)

    task_a =
      Task.async(fn ->
        send(parent, {:worker_ready, :a, self()})

        receive do
          :run_worker -> perform_job(WhatsAppInboundWorker, args_a)
        end
      end)

    task_a_pid = task_a.pid
    assert_receive {:worker_ready, :a, ^task_a_pid}
    Sandbox.allow(Repo, self(), task_a.pid)
    send(task_a.pid, :run_worker)

    assert_receive {:whatsapp_request, 1, _first_request}

    task_b =
      Task.async(fn ->
        send(parent, {:worker_ready, :b, self()})

        receive do
          :run_worker -> perform_job(WhatsAppInboundWorker, args_b)
        end
      end)

    task_b_pid = task_b.pid
    assert_receive {:worker_ready, :b, ^task_b_pid}
    Sandbox.allow(Repo, self(), task_b.pid)
    send(task_b.pid, :run_worker)

    refute_receive {:whatsapp_request, 2, _request}, 100
    assert {:snooze, snooze_seconds} = Task.await(task_b, 5_000)
    assert snooze_seconds > 0

    send(task_a.pid, :release_first_request)
    assert :ok = Task.await(task_a, 5_000)

    assert :ok = perform_job(WhatsAppInboundWorker, args_b)
    assert_received {:whatsapp_request, 2, _second_request}
    assert :counters.get(counter, 1) == 2
    assert conversation_state(conversation_id) == "selecting_event"
    assert conversation_transition_count(conversation_id) == 2

    {state_data, _needs_human, _handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["last_handled_inbound_message_id"] == args_b["provider_message_id"]
    assert state_data["pending_reply"]["provider_message_id"] == args_b["provider_message_id"]
    assert state_data["pending_reply"]["status"] == "reply_sent"
    assert is_nil(state_data["pending_reply"]["ciphertext"])
  end

  test "storing a distinct provider reply fails closed while another reply is unresolved" do
    {:ok, ciphertext} = Crypto.encrypt("reply A")

    conversation_id =
      insert_conversation!(
        state: "main_menu",
        state_data: %{
          "last_handled_inbound_message_id" => "wamid.pending-a",
          "pending_reply" => %{
            "ciphertext" => ciphertext,
            "provider_message_id" => "wamid.pending-a",
            "status" => "reply_retryable",
            "attempt_count" => 1
          }
        }
      )

    conversation = reload_conversation!(conversation_id)
    {:ok, other_ciphertext} = Crypto.encrypt("reply B")

    assert {:error, %Invalid{} = error} =
             conversation
             |> Changeset.for_update(
               :store_pending_reply,
               %{
                 ciphertext: other_ciphertext,
                 provider_message_id: "wamid.pending-b",
                 computed_at: DateTime.utc_now() |> DateTime.truncate(:second)
               },
               actor: %{actor_type: :system, actor_id: "test"}
             )
             |> Ash.update(authorize?: false)

    assert inspect(error) =~ "reply delivery is already pending"
    reloaded = reload_conversation!(conversation_id)
    assert reloaded.state_data["pending_reply"]["provider_message_id"] == "wamid.pending-a"
    assert reloaded.state_data["pending_reply"]["ciphertext"] == ciphertext
  end

  test "permanent Meta reply failure becomes an operator-visible terminal outcome" do
    provider_error = "META_PROVIDER_ERROR_SENTINEL"
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 400,
         body: Jason.encode!(%{"error" => %{"message" => provider_error}})
       }}
    end)

    conversation_id = insert_conversation!(state: "selecting_language")
    {:ok, encrypted} = Crypto.encrypt("1")
    args = inbound_worker_args(conversation_id, "wamid.worker-permanent-1", encrypted)

    log =
      capture_log(fn ->
        assert {:discard, :whatsapp_reply_failed} = perform_job(WhatsAppInboundWorker, args)
      end)

    assert_received {:whatsapp_request, _request}
    assert conversation_state(conversation_id) == "main_menu"

    {state_data, needs_human, handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["pending_reply"]["status"] == "reply_failed"
    assert is_nil(state_data["pending_reply"]["ciphertext"])
    assert needs_human
    assert handoff_reason == "whatsapp_reply_validation_failure"
    refute inspect(state_data) =~ provider_error
    refute log =~ provider_error
  end

  test "final retryable Meta failure becomes retry-exhausted terminal outcome" do
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 500,
         body: Jason.encode!(%{"error" => %{"message" => "META_PROVIDER_ERROR_SENTINEL"}})
       }}
    end)

    conversation_id = insert_conversation!(state: "selecting_language")
    {:ok, encrypted} = Crypto.encrypt("1")
    args = inbound_worker_args(conversation_id, "wamid.worker-exhausted-1", encrypted)
    job = build_job(WhatsAppInboundWorker, args, attempt: 5)

    assert {:discard, :whatsapp_reply_retry_exhausted} = perform_job(job)
    assert_received {:whatsapp_request, _request}
    assert conversation_state(conversation_id) == "main_menu"

    {state_data, needs_human, handoff_reason} = conversation_delivery_data(conversation_id)
    assert state_data["pending_reply"]["status"] == "reply_failed"
    assert is_nil(state_data["pending_reply"]["ciphertext"])
    assert needs_human
    assert handoff_reason == "whatsapp_reply_retry_exhausted"
  end

  test "retrying a failed reply does not repeat checkout payment or inventory effects" do
    paystack_cleanup = PaymentSupport.setup_paystack!()
    on_exit(paystack_cleanup)

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Retry Checkout Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "Retry Checkout General")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    state_data = %{
      "selected_event_id" => event.id,
      "selected_event_label" => event.name,
      "selected_offer_id" => offer.id,
      "selected_offer_label" => offer.name,
      "selected_offer_max_per_order" => offer.max_per_order,
      "selected_offer_price_cents" => offer.price_cents,
      "selected_offer_currency" => offer.currency,
      "quantity" => 1,
      "buyer_name" => "Retry Buyer",
      "buyer_email" => "retry-buyer@example.com"
    }

    conversation_id = insert_conversation!(state: "confirming_order", state_data: state_data)
    {:ok, encrypted} = Crypto.encrypt("1")
    args = inbound_worker_args(conversation_id, "wamid.worker-checkout-retry-1", encrypted)
    counter = :counters.new(1, [])
    test_pid = self()

    Application.put_env(:fastcheck, :paystack_request_fun, PaymentSupport.success_request_fun())

    Application.put_env(
      :fastcheck,
      :whatsapp_request_fun,
      retryable_then_success_request_fun(test_pid, counter, "wamid.outbound-checkout-retry")
    )

    before = sales_effect_counts()
    inventory_before = SalesE2EFixtures.inventory_snapshot!(offer.id)

    assert {:error, :whatsapp_send_retryable} = perform_job(WhatsAppInboundWorker, args)
    assert_received {:whatsapp_request, 1, _request}
    assert :counters.get(counter, 1) == 1

    after_first = sales_effect_counts()
    assert after_first.orders == before.orders + 1
    assert after_first.order_lines == before.order_lines + 1
    assert after_first.payment_attempts == before.payment_attempts + 1
    inventory_after_first = SalesE2EFixtures.inventory_snapshot!(offer.id)
    refute inventory_after_first == inventory_before
    assert pending_order_id(conversation_id)
    assert length(all_enqueued(worker: FastCheck.Workers.SendWhatsAppPaymentLinkWorker)) == 1

    assert :ok = perform_job(WhatsAppInboundWorker, args)
    assert_received {:whatsapp_request, 2, _request}
    assert :counters.get(counter, 1) == 2

    assert sales_effect_counts() == after_first
    assert SalesE2EFixtures.inventory_snapshot!(offer.id) == inventory_after_first
    assert length(all_enqueued(worker: FastCheck.Workers.SendWhatsAppPaymentLinkWorker)) == 1
  end

  test "checkpoint preserves event options so event selection advances to ticket offers" do
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.outbound-flow"}]})
       }}
    end)

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Checkpoint Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "Checkpoint General")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    assert :ok = checkpoint_and_perform_inbound("wamid.checkpoint-flow-1", "hi")
    assert_received {:whatsapp_request, request}
    assert request.options.json["text"]["body"] =~ "Welkom by FastCheck Tickets"

    assert :ok = checkpoint_and_perform_inbound("wamid.checkpoint-flow-2", "1")
    assert_received {:whatsapp_request, request}
    assert request.options.json["text"]["body"] =~ "Koop kaartjies"

    assert :ok = checkpoint_and_perform_inbound("wamid.checkpoint-flow-3", "1")
    assert_received {:whatsapp_request, request}
    assert request.options.json["text"]["body"] =~ "Checkpoint Event"

    {state, state_data} = latest_conversation_state_and_data()
    assert state == "selecting_event"
    assert state_data["event_options"] == %{"1" => event.id}

    assert {:ok, checkpointed} =
             InboundCheckpoint.checkpoint(
               inbound_command("wamid.checkpoint-flow-4", "1"),
               86_400
             )

    assert checkpointed.state == "selecting_event"
    assert checkpointed.state_data["event_options"] == %{"1" => event.id}

    assert :ok = perform_inbound_worker(checkpointed.id, "wamid.checkpoint-flow-4", "1")
    assert_received {:whatsapp_request, request}
    assert request.options.json["text"]["body"] =~ "Checkpoint General"

    {state, state_data} = latest_conversation_state_and_data()
    assert state == "selecting_ticket_type"
    assert state_data["event_options"] == %{"1" => event.id}
    assert state_data["selected_event_id"] == event.id
    assert state_data["offer_options"] == %{"1" => offer.id}
  end

  defp checkpoint_and_perform_inbound(provider_message_id, text) do
    with {:ok, conversation} <-
           InboundCheckpoint.checkpoint(inbound_command(provider_message_id, text), 86_400) do
      perform_inbound_worker(conversation.id, provider_message_id, text)
    end
  end

  defp perform_inbound_worker(conversation_id, provider_message_id, text) do
    {:ok, encrypted} = Crypto.encrypt(text)

    perform_job(WhatsAppInboundWorker, %{
      "provider_message_id" => provider_message_id,
      "message_type" => "text",
      "text_body_encrypted" => encrypted,
      "text_body_redacted_or_reference" => "[FILTERED_MESSAGE]",
      "conversation_id" => conversation_id,
      "correlation_id" => "corr-#{provider_message_id}",
      "received_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "raw_payload_hash" => "hash-#{provider_message_id}"
    })
  end

  defp inbound_command(provider_message_id, text) do
    %MessageCommand{
      provider: "meta",
      provider_message_id: provider_message_id,
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      message_type: "text",
      text_body: text,
      received_at: DateTime.utc_now() |> DateTime.truncate(:second),
      raw_payload_hash: "hash-#{provider_message_id}",
      correlation_id: "corr-#{provider_message_id}",
      metadata: %{}
    }
  end

  defp latest_conversation_state_and_data do
    %{rows: [[state, state_data]]} =
      Repo.query!("""
      SELECT state, state_data
      FROM sales_conversations
      WHERE wa_id = '27821234567'
      ORDER BY inserted_at DESC
      LIMIT 1
      """)

    {state, state_data}
  end

  defp insert_conversation!(opts \\ []) do
    state = Keyword.get(opts, :state, "new")
    state_data = Keyword.get(opts, :state_data, %{})

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES
          ('+27821234567', '27821234567', 'af', $1, $2::jsonb, false, now(), now())
        RETURNING id
        """,
        [state, state_data]
      )

    id
  end

  defp conversation_state(conversation_id) do
    %{rows: [[state]]} =
      Repo.query!("SELECT state FROM sales_conversations WHERE id = $1", [conversation_id])

    state
  end

  defp pending_order_id(conversation_id) do
    %{rows: [[order_id]]} =
      Repo.query!(
        "SELECT state_data->>'sales_order_id' FROM sales_conversations WHERE id = $1",
        [conversation_id]
      )

    order_id
  end

  defp sales_effect_counts do
    %{rows: [[orders]]} = Repo.query!("SELECT count(*) FROM sales_orders")
    %{rows: [[order_lines]]} = Repo.query!("SELECT count(*) FROM sales_order_lines")
    %{rows: [[payment_attempts]]} = Repo.query!("SELECT count(*) FROM sales_payment_attempts")

    %{orders: orders, order_lines: order_lines, payment_attempts: payment_attempts}
  end

  defp conversation_transition_count(conversation_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM sales_state_transitions
        WHERE entity_type = 'conversation' AND entity_id = $1
        """,
        [to_string(conversation_id)]
      )

    count
  end

  defp conversation_delivery_data(conversation_id) do
    %{rows: [[state_data, needs_human, handoff_reason]]} =
      Repo.query!(
        """
        SELECT state_data, needs_human, handoff_reason
        FROM sales_conversations
        WHERE id = $1
        """,
        [conversation_id]
      )

    {state_data, needs_human, handoff_reason}
  end

  defp reload_conversation!(conversation_id) do
    Conversation
    |> Query.for_read(:get_by_id, %{id: conversation_id})
    |> Ash.read_one!(authorize?: false)
  end

  defp inbound_worker_args(conversation_id, provider_message_id, encrypted) do
    %{
      "provider_message_id" => provider_message_id,
      "message_type" => "text",
      "text_body_encrypted" => encrypted,
      "text_body_redacted_or_reference" => "[FILTERED_MESSAGE]",
      "conversation_id" => conversation_id,
      "correlation_id" => "corr-#{provider_message_id}",
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "raw_payload_hash" => "hash-#{provider_message_id}"
    }
  end

  defp retryable_then_success_request_fun(test_pid, counter, outbound_message_id) do
    fn request ->
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)
      send(test_pid, {:whatsapp_request, attempt, request})

      if attempt == 1 do
        {:ok,
         %Req.Response{
           status: 500,
           body: Jason.encode!(%{"error" => %{"message" => "temporary provider failure"}})
         }}
      else
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"messages" => [%{"id" => outbound_message_id}]})
         }}
      end
    end
  end

  defp scanner_code do
    System.unique_integer([:positive])
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
