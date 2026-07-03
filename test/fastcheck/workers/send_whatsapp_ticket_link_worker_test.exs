defmodule FastCheck.Workers.SendWhatsAppTicketLinkWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ash.Changeset
  alias FastCheck.Fixtures
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Sales.TicketResendChallenge
  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.Resend.Hash
  alias FastCheck.Tickets.TokenHash
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker

  setup do
    WebhookTestSupport.flush_redis_keys!()
    cleanup = WebhookTestSupport.setup_whatsapp!()

    on_exit(fn ->
      WebhookTestSupport.flush_redis_keys!()
      cleanup.()
    end)

    :ok
  end

  test "does not treat QR inside the opaque delivery token as direct ticket payload leakage" do
    body =
      "Jou kaartjie is gereed. Maak jou veilige kaartjieskakel hier oop: " <>
        "http://localhost:4002/t/abcQRdef123"

    token = extract_ticket_link_token!(body)
    redacted_body = redact_delivery_token!(body, token)

    assert token == "abcQRdef123"
    assert redacted_body =~ "/t/[redacted]"
    assert_no_direct_ticket_payload!(redacted_body)
  end

  test "rotates a fresh delivery token and sends only a secure ticket page link" do
    test_pid = self()

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.ticket-out"}]})
       }}
    end)

    log =
      capture_log(fn ->
        assert :ok =
                 perform_job(SendWhatsAppTicketLinkWorker, %{
                   "conversation_id" => conversation_id,
                   "sales_order_id" => order_id,
                   "ticket_issue_id" => issue_id
                 })
      end)

    assert_received {:whatsapp_request, request}
    assert request.options.json["type"] == "text"
    body = request.options.json["text"]["body"]
    assert body =~ "/t/"

    token = extract_ticket_link_token!(body)
    redacted_body = redact_delivery_token!(body, token)

    assert_no_direct_ticket_payload!(redacted_body)

    updated = Repo.get!(TicketIssue, issue_id)
    assert updated.delivery_token_hash != old_hash
    refute body =~ updated.delivery_token_hash
    refute log =~ updated.delivery_token_hash
    assert TokenHash.verify(token, updated.delivery_token_hash, :delivery)

    assert [%{status: "sent", provider_message_id: "wamid.ticket-out"}] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select:
                   map(d, [
                     :status,
                     :provider_message_id,
                     :within_whatsapp_window,
                     :template_name
                   ])
             )
             |> Enum.map(fn row ->
               assert row.within_whatsapp_window == true
               assert row.template_name == nil
               Map.take(row, [:status, :provider_message_id])
             end)
  end

  test "sends ticket link with approved template outside the 24 hour window" do
    test_pid = self()

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture(
        last_message_at: DateTime.utc_now() |> DateTime.add(-25, :hour),
        preferred_language: "en"
      )

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.ticket-template"}]})
       }}
    end)

    assert :ok =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id
             })

    assert_received {:whatsapp_request, request}
    assert request.options.json["type"] == "template"
    assert request.options.json["template"]["name"] == "fastcheck_ticket_ready_en"
    assert request.options.json["template"]["language"]["code"] == "en_US"

    body_param =
      request.options.json["template"]["components"]
      |> hd()
      |> get_in(["parameters"])
      |> hd()

    assert body_param["type"] == "text"
    assert body_param["text"] =~ "/t/"

    assert [
             %{
               status: "sent",
               provider_message_id: "wamid.ticket-template",
               within_whatsapp_window: false,
               template_name: "fastcheck_ticket_ready_en"
             }
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select:
                   map(d, [
                     :status,
                     :provider_message_id,
                     :within_whatsapp_window,
                     :template_name
                   ])
             )
  end

  test "duplicate successful execution sends one ticket link inside dedupe TTL" do
    test_pid = self()

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.ticket-dedupe"}]})
       }}
    end)

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id
    }

    assert :ok = perform_job(SendWhatsAppTicketLinkWorker, args)
    assert :ok = perform_job(SendWhatsAppTicketLinkWorker, args)

    assert_received {:whatsapp_request, _request}
    refute_received {:whatsapp_request, _duplicate}

    assert {:ok, ttl} =
             Redix.command(FastCheck.Redix, [
               "TTL",
               "fastcheck:whatsapp:dedupe:send_ticket_link:#{conversation_id}:#{issue_id}"
             ])

    assert ttl > 80_000

    assert ["sent"] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: d.status
             )
  end

  test "verified resend challenge sends link and marks challenge consumed" do
    test_pid = self()

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.resend-ticket"}]})
       }}
    end)

    assert :ok =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => challenge.id,
               "delivery_reason" => "verified_ticket_resend"
             })

    assert_received {:whatsapp_request, request}
    assert request.options.json["text"]["body"] =~ "/t/"

    assert %{status: "consumed", consumed_at: consumed_at} =
             resend_challenge_snapshot(challenge.id)

    assert consumed_at
  end

  test "invalid resend challenge discards before dedupe claim token rotation or send" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    mismatched_conversation_id = insert_worker_conversation!()
    mismatched = verified_resend_challenge!(mismatched_conversation_id, order_id, issue_id)
    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("mismatched resend challenge must not send")
    end)

    assert {:discard, :invalid_resend_challenge} =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => mismatched.id,
               "delivery_reason" => "verified_ticket_resend"
             })

    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash == old_hash

    assert {:ok, -2} =
             Redix.command(FastCheck.Redix, [
               "TTL",
               "fastcheck:whatsapp:dedupe:send_ticket_link:#{conversation_id}:#{issue_id}"
             ])

    assert [] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: d.status
             )
  end

  test "consumed resend challenge discards before dedupe claim token rotation or send" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)
    consume_resend_challenge!(challenge.id)
    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("consumed resend challenge must not send")
    end)

    assert {:discard, :invalid_resend_challenge} =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => challenge.id,
               "delivery_reason" => "verified_ticket_resend"
             })

    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash == old_hash

    assert {:ok, -2} =
             Redix.command(FastCheck.Redix, [
               "TTL",
               "fastcheck:whatsapp:dedupe:send_ticket_link:#{conversation_id}:#{issue_id}"
             ])
  end

  test "does not send active link for revoked ticket issue" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture(status: "revoked", revoked_at: DateTime.utc_now())

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("revoked ticket must not be sent")
    end)

    assert {:discard, :ticket_not_deliverable} =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id
             })
  end

  test "resend challenge is not consumed when ticket is not deliverable" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture(status: "revoked", revoked_at: DateTime.utc_now())

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("revoked ticket must not be sent")
    end)

    assert {:discard, :ticket_not_deliverable} =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => challenge.id,
               "delivery_reason" => "verified_ticket_resend"
             })

    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)
  end

  test "marks DeliveryAttempt failed without storing ticket token when WhatsApp send fails" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      {:ok,
       %Req.Response{
         status: 500,
         body: Jason.encode!(%{"error" => %{"message" => "raw provider message"}})
       }}
    end)

    assert {:error, %{retryable?: true}} =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id
             })

    updated = Repo.get!(TicketIssue, issue_id)

    assert [
             %{
               status: "failed",
               provider_error_message: "whatsapp send failed",
               failure_reason: "server_error"
             }
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: map(d, [:status, :provider_error_message, :failure_reason])
             )

    attempt_log =
      Repo.one!(
        from d in "sales_delivery_attempts",
          where: d.ticket_issue_id == ^issue_id,
          select: d.provider_error_message
      )

    refute attempt_log =~ updated.delivery_token_hash
  end

  test "marks DeliveryAttempt manual_review for Meta auth errors without retrying forever" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      {:ok,
       %Req.Response{
         status: 401,
         body: Jason.encode!(%{"error" => %{"code" => 190, "message" => "bad token"}})
       }}
    end)

    log =
      capture_log(fn ->
        assert {:discard, :manual_review} =
                 perform_job(SendWhatsAppTicketLinkWorker, %{
                   "conversation_id" => conversation_id,
                   "sales_order_id" => order_id,
                   "ticket_issue_id" => issue_id
                 })
      end)

    updated = Repo.get!(TicketIssue, issue_id)
    assert updated.delivery_token_hash != old_hash

    assert [
             %{
               status: "manual_review",
               provider_error_code: "190",
               provider_error_message: "whatsapp send failed",
               failure_reason: "auth_error",
               fallback_channel: "manual_review"
             } = attempt
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select:
                   map(d, [
                     :status,
                     :provider_error_code,
                     :provider_error_message,
                     :failure_reason,
                     :fallback_channel
                   ])
             )

    refute attempt.provider_error_message =~ updated.delivery_token_hash
    refute attempt.failure_reason =~ updated.delivery_token_hash
    refute log =~ updated.delivery_token_hash
    refute log =~ "/t/"
  end

  test "releases outbound dedupe after retryable failure so retry sends ticket link" do
    test_pid = self()
    counter = :counters.new(1, [])

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          {:ok,
           %Req.Response{
             status: 500,
             body: Jason.encode!(%{"error" => %{"message" => "retry later"}})
           }}

        _ ->
          {:ok,
           %Req.Response{
             status: 200,
             body: Jason.encode!(%{"messages" => [%{"id" => "wamid.ticket-retry"}]})
           }}
      end
    end)

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id
    }

    assert {:error, %{retryable?: true}} = perform_job(SendWhatsAppTicketLinkWorker, args)
    assert :ok = perform_job(SendWhatsAppTicketLinkWorker, args)

    assert_received {:whatsapp_request, _failed_request}
    assert_received {:whatsapp_request, _retry_request}
    refute_received {:whatsapp_request, _extra_request}

    assert ["failed", "sent"] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 order_by: [asc: d.id],
                 select: d.status
             )
  end

  test "resend provider retryable failure does not consume and releases dedupe" do
    test_pid = self()
    counter = :counters.new(1, [])

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          {:ok,
           %Req.Response{
             status: 500,
             body: Jason.encode!(%{"error" => %{"message" => "retry later"}})
           }}

        _ ->
          {:ok,
           %Req.Response{
             status: 200,
             body: Jason.encode!(%{"messages" => [%{"id" => "wamid.resend-retry"}]})
           }}
      end
    end)

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id,
      "ticket_resend_challenge_id" => challenge.id,
      "delivery_reason" => "verified_ticket_resend"
    }

    assert {:error, %{retryable?: true}} = perform_job(SendWhatsAppTicketLinkWorker, args)
    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)

    assert :ok = perform_job(SendWhatsAppTicketLinkWorker, args)

    assert %{status: "consumed", consumed_at: consumed_at} =
             resend_challenge_snapshot(challenge.id)

    assert consumed_at

    assert_received {:whatsapp_request, _failed_request}
    assert_received {:whatsapp_request, _retry_request}
  end

  test "provider success plus consume failure is non-retryable and keeps dedupe claimed" do
    test_pid = self()

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})
      consume_resend_challenge!(challenge.id)

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.consume-race"}]})
       }}
    end)

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id,
      "ticket_resend_challenge_id" => challenge.id,
      "delivery_reason" => "verified_ticket_resend"
    }

    assert {:discard, :resend_challenge_consume_failed} =
             perform_job(SendWhatsAppTicketLinkWorker, args)

    assert {:discard, :invalid_resend_challenge} = perform_job(SendWhatsAppTicketLinkWorker, args)

    assert_received {:whatsapp_request, _request}
    refute_received {:whatsapp_request, _duplicate}

    assert {:ok, ttl} =
             Redix.command(FastCheck.Redix, [
               "TTL",
               "fastcheck:whatsapp:dedupe:send_ticket_link:#{conversation_id}:#{issue_id}"
             ])

    assert ttl > 0
  end

  defp extract_ticket_link_token!(body) when is_binary(body) do
    case Regex.run(~r{/t/([^[:space:]]+)}, body) do
      [_, token] -> token
      _ -> flunk("expected WhatsApp body to contain a /t/<delivery-token> ticket link")
    end
  end

  defp redact_delivery_token!(body, token) when is_binary(body) and is_binary(token) do
    if String.contains?(body, token) do
      String.replace(body, token, "[redacted]", global: false)
    else
      flunk("expected WhatsApp body to contain extracted delivery token")
    end
  end

  defp assert_no_direct_ticket_payload!(redacted_body) when is_binary(redacted_body) do
    refute redacted_body =~ "QR"
    refute redacted_body =~ "qr_token"
    refute redacted_body =~ "ticket_code"
    refute redacted_body =~ "delivery_token_hash"
    refute redacted_body =~ "ticket_url"
  end

  defp issued_ticket_fixture(opts \\ []) do
    event = Fixtures.create_event()
    attendee = Fixtures.create_attendee(event, %{payment_status: "completed"})
    token = DeliveryToken.generate(ttl_seconds: 3600)
    {order_id, order_line_id} = insert_order_with_line!(event.id)

    attrs = %{
      sales_order_id: order_id,
      sales_order_line_id: order_line_id,
      line_item_sequence: 1,
      attendee_id: attendee.id,
      ticket_code: attendee.ticket_code,
      qr_token_hash: TokenHash.hash("qr-#{System.unique_integer([:positive])}", :qr),
      delivery_token_hash: token.hash,
      delivery_token_expires_at: token.expires_at
    }

    assert {:ok, issue} =
             TicketIssue
             |> Changeset.for_create(:create_issued_link, attrs, actor: system_actor())
             |> Ash.create(authorize?: false)

    if Keyword.get(opts, :status, "issued") != "issued" or Keyword.get(opts, :revoked_at) do
      Repo.query!(
        "UPDATE sales_ticket_issues SET status = $1, revoked_at = $2 WHERE id = $3",
        [Keyword.get(opts, :status, "issued"), Keyword.get(opts, :revoked_at), issue.id]
      )
    end

    preferred_language = Keyword.get(opts, :preferred_language, "af")
    last_message_at = Keyword.get(opts, :last_message_at, DateTime.utc_now())

    %{rows: [[conversation_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, last_message_at, needs_human, inserted_at, updated_at)
        VALUES
          ('+27821234567', '27821234567', $1, 'ticket_issued', $2, $3, false, now(), now())
        RETURNING id
        """,
        [preferred_language, %{"sales_order_id" => order_id}, last_message_at]
      )

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue.id}
  end

  defp verified_resend_challenge!(conversation_id, order_id, ticket_issue_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    public_id = "resend-#{System.unique_integer([:positive])}"

    assert {:ok, challenge} =
             TicketResendChallenge
             |> Changeset.for_create(
               :create_pending,
               %{
                 public_id: public_id,
                 sales_order_id: order_id,
                 ticket_issue_id: ticket_issue_id,
                 conversation_id: conversation_id,
                 request_email_hash: Hash.email("buyer@example.com"),
                 request_name_hash: Hash.name("buyer"),
                 source_hash: Hash.source(%{conversation_id: conversation_id}),
                 candidate_hash: Hash.candidate(order_id, ticket_issue_id),
                 otp_hash: Hash.otp(public_id, "123456"),
                 expires_at: DateTime.add(now, 300, :second),
                 metadata: %{}
               },
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    assert {:ok, verified} =
             challenge
             |> Changeset.for_update(:mark_verified, %{verified_at: now}, actor: system_actor())
             |> Ash.update(authorize?: false)

    verified
  end

  defp insert_worker_conversation! do
    unique =
      System.unique_integer([:positive])
      |> rem(10_000_000)
      |> Integer.to_string()
      |> String.pad_leading(7, "0")

    %{rows: [[conversation_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, last_message_at, needs_human, inserted_at, updated_at)
        VALUES
          ($1, $2, 'af', 'ticket_issued', '{}', now(), false, now(), now())
        RETURNING id
        """,
        ["+2782#{unique}", "wa-#{unique}"]
      )

    conversation_id
  end

  defp consume_resend_challenge!(challenge_id) do
    Repo.update_all(
      from(c in "sales_ticket_resend_challenges", where: c.id == ^challenge_id),
      set: [status: "consumed", consumed_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end

  defp resend_challenge_snapshot(challenge_id) do
    Repo.one!(
      from c in "sales_ticket_resend_challenges",
        where: c.id == ^challenge_id,
        select: map(c, [:status, :consumed_at])
    )
  end

  defp insert_order_with_line!(event_id) do
    %{rows: [[offer_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, lock_version, inserted_at, updated_at)
        VALUES
          ($1, 'GA', 'general', 100, 'ZAR', 10, 10, 5, true, 'whatsapp', 1, now(), now())
        RETURNING id
        """,
        [event_id]
      )

    %{rows: [[order_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, ticket_issued_at, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer', '+27821234567', 'buyer@example.com', 'whatsapp',
           'ticket_issued', 100, 'ZAR', now(), now(), now())
        RETURNING id
        """,
        ["FC-#{System.unique_integer([:positive])}", event_id]
      )

    %{rows: [[line_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'general', 'GA', 'Event', 1, 100, 100, 'ZAR', '{}', now(), now())
        RETURNING id
        """,
        [order_id, offer_id]
      )

    {order_id, line_id}
  end

  defp system_actor, do: %{actor_type: :system, actor_id: "vs-19-ticket-link-test"}
end
