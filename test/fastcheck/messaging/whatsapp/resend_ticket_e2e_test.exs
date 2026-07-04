defmodule FastCheck.Messaging.WhatsApp.ResendTicketE2ETest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import ExUnit.CaptureLog
  import FastCheck.TicketResendFixtures
  import Swoosh.TestAssertions

  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.ConversationStateMachine
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.TicketPage
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker

  setup :set_swoosh_global

  setup do
    WebhookTestSupport.flush_redis_keys!()
    cleanup = WebhookTestSupport.setup_whatsapp!()

    on_exit(fn ->
      WebhookTestSupport.flush_redis_keys!()
      cleanup.()
    end)

    {:ok, conversation: insert_conversation!()}
  end

  test "customer completes WhatsApp resend flow and receives audited secure ticket link", %{
    conversation: conversation
  } do
    test_pid = self()

    candidate =
      issued_ticket_candidate!(buyer_email: "resend@example.com", buyer_name: "Jamie Smith")

    {{verified, otp}, flow_log} =
      capture_result_and_log(fn ->
        conversation
        |> progress("hi", "e2e-1")
        |> progress("1", "e2e-2")
        |> progress("3", "e2e-3")
        |> progress("Jamie Smith", "e2e-4")
        |> progress("resend@example.com", "e2e-5")
        |> then(fn result ->
          otp = extract_single_otp_from_email!()
          assert {:ok, verified} = handle(result.conversation, otp, "wamid.e2e-6")
          refute verified.response_body =~ "http://"
          refute verified.response_body =~ "https://"
          refute verified.response_body =~ "/t/"
          refute verified.response_body =~ otp
          {verified, otp}
        end)
      end)

    assert verified.conversation.state == "verified_resend_delivery_queued"
    assert verified.response_body =~ "gereed"

    challenge =
      Repo.one!(
        from c in "sales_ticket_resend_challenges",
          where: c.status == "verified",
          select:
            map(c, [
              :id,
              :public_id,
              :sales_order_id,
              :ticket_issue_id,
              :status,
              :consumed_at
            ])
      )

    assert challenge.consumed_at == nil
    assert_safe_flow_log!(flow_log, candidate, challenge.public_id, otp)

    assert_enqueued(
      worker: SendWhatsAppTicketLinkWorker,
      args: %{
        "conversation_id" => verified.conversation.id,
        "sales_order_id" => challenge.sales_order_id,
        "ticket_issue_id" => challenge.ticket_issue_id,
        "ticket_resend_challenge_id" => challenge.id,
        "delivery_reason" => "verified_ticket_resend"
      }
    )

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.e2e-resend-ticket"}]})
       }}
    end)

    worker_log =
      capture_log(fn ->
        assert :ok =
                 perform_job(SendWhatsAppTicketLinkWorker, %{
                   "conversation_id" => verified.conversation.id,
                   "sales_order_id" => challenge.sales_order_id,
                   "ticket_issue_id" => challenge.ticket_issue_id,
                   "ticket_resend_challenge_id" => challenge.id,
                   "delivery_reason" => "verified_ticket_resend"
                 })
      end)

    assert_received {:whatsapp_request, request}
    assert request.options.json["type"] == "text"
    refute Map.has_key?(request.options.json, "document")
    refute Map.has_key?(request.options.json, "attachment")
    refute Map.has_key?(request.options.json, "filename")

    body = request.options.json["text"]["body"]
    assert body =~ "/t/"
    token = extract_ticket_link_token!(body)
    assert %{state: :valid} = TicketPage.resolve(token)
    assert_safe_worker_log!(worker_log, candidate, challenge.public_id, otp, token)

    assert %{status: "consumed", consumed_at: consumed_at} =
             resend_challenge_snapshot(challenge.id)

    assert consumed_at

    assert [
             %{
               status: "sent",
               delivery_reason: "verified_ticket_resend",
               ticket_resend_challenge_id: challenge_id,
               provider_message_id: "wamid.e2e-resend-ticket"
             }
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^challenge.ticket_issue_id,
                 select:
                   map(d, [
                     :status,
                     :delivery_reason,
                     :ticket_resend_challenge_id,
                     :provider_message_id
                   ])
             )

    assert challenge_id == challenge.id
  end

  defp progress(%{conversation: conversation}, text, suffix),
    do: progress(conversation, text, suffix)

  defp progress(%Conversation{} = conversation, text, suffix) do
    assert {:ok, result} = handle(conversation, text, "wamid.progress-#{suffix}")
    result
  end

  defp handle(conversation, text, provider_message_id) do
    command = %MessageCommand{
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

    ConversationStateMachine.handle_inbound(command, conversation)
  end

  defp insert_conversation! do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES
          ('+27821234567', '27821234567', 'af', 'new', '{}', false, now(), now())
        RETURNING id
        """,
        []
      )

    Conversation
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp extract_single_otp_from_email! do
    assert_received {:email, email}

    case Regex.run(~r/\b\d{6}\b/, email.text_body || "") do
      [otp] -> otp
      _ -> flunk("expected OTP email body to contain a six-digit code")
    end
  end

  defp extract_ticket_link_token!(body) when is_binary(body) do
    case Regex.run(~r{/t/([^[:space:]]+)}, body) do
      [_, token] -> token
      _ -> flunk("expected WhatsApp body to contain a /t/<delivery-token> ticket link")
    end
  end

  defp resend_challenge_snapshot(challenge_id) do
    Repo.one!(
      from c in "sales_ticket_resend_challenges",
        where: c.id == ^challenge_id,
        select: map(c, [:status, :consumed_at])
    )
  end

  defp capture_result_and_log(fun) do
    ref = make_ref()

    log =
      capture_log(fn ->
        send(self(), {ref, fun.()})
      end)

    assert_received {^ref, result}
    {result, log}
  end

  defp assert_safe_flow_log!(log, candidate, public_id, otp) do
    refute log =~ otp
    refute log =~ public_id
    refute log =~ candidate.buyer_email
    refute log =~ candidate.buyer_name
    refute log =~ candidate.ticket_code
    refute log =~ "+27821234567"
    refute log =~ "/t/"
    refute log =~ "delivery_token"
    refute log =~ "qr_token"
    refute log =~ "provider_payload"
  end

  defp assert_safe_worker_log!(log, candidate, public_id, otp, token) do
    assert_safe_flow_log!(log, candidate, public_id, otp)
    refute log =~ token
    refute log =~ "delivery_token_hash"
    refute log =~ "qr_token_hash"
  end
end
