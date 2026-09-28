defmodule FastCheck.Workers.SendWhatsAppTicketLinkWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ash.Changeset
  alias FastCheck.Fixtures
  alias FastCheck.Messaging.WhatsApp.Dedupe
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Repo
  alias FastCheck.Sales.DeliveryAttempt
  alias FastCheck.Sales.TicketDeliveryIntent
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

  test "worker accepts only the durable intent ID and derives the rest from PostgreSQL" do
    %{ticket_delivery_intent_id: intent_id, ticket_issue_id: issue_id} = issued_ticket_fixture()
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.intent-only"}]})
       }}
    end)

    assert {:discard, :invalid_args} =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "ticket_delivery_intent_id" => intent_id,
               "ticket_issue_id" => issue_id
             })

    assert :ok =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "ticket_delivery_intent_id" => intent_id
             })

    assert_received {:whatsapp_request, request}
    assert request.options.json["type"] == "text"

    assert [attempt] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_delivery_intent_id == ^intent_id,
                 select: map(d, [:sales_order_id, :ticket_issue_id, :attempt_number])
             )

    assert attempt.ticket_issue_id == issue_id
    assert attempt.attempt_number == 1
  end

  test "intent order and conversation cross-links fail before token rotation or provider HTTP" do
    first = issued_ticket_fixture()
    second = issued_ticket_fixture()
    old_hash = Repo.get!(TicketIssue, first.ticket_issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("cross-linked intent must not send")
    end)

    Repo.update_all(
      from(i in "sales_ticket_delivery_intents", where: i.id == ^first.ticket_delivery_intent_id),
      set: [sales_order_id: second.order_id]
    )

    assert {:discard, :manual_review} =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "ticket_delivery_intent_id" => first.ticket_delivery_intent_id
             })

    assert Repo.get!(TicketIssue, first.ticket_issue_id).delivery_token_hash == old_hash

    second_hash = Repo.get!(TicketIssue, second.ticket_issue_id).delivery_token_hash

    Repo.update_all(
      from(i in "sales_ticket_delivery_intents",
        where: i.id == ^second.ticket_delivery_intent_id
      ),
      set: [conversation_id: first.conversation_id]
    )

    assert {:discard, :manual_review} =
             perform_job(SendWhatsAppTicketLinkWorker, %{
               "ticket_delivery_intent_id" => second.ticket_delivery_intent_id
             })

    assert Repo.get!(TicketIssue, second.ticket_issue_id).delivery_token_hash == second_hash
    refute_received {:whatsapp_request, _request}

    assert 0 ==
             Repo.one!(
               from d in "sales_delivery_attempts",
                 where:
                   d.ticket_delivery_intent_id in ^[
                     first.ticket_delivery_intent_id,
                     second.ticket_delivery_intent_id
                   ],
                 select: count(d.id)
             )
  end

  test "resend challenge order cross-link fails closed" do
    first = issued_ticket_fixture()
    second = issued_ticket_fixture()

    challenge =
      verified_resend_challenge!(second.conversation_id, second.order_id, second.ticket_issue_id)

    Repo.update_all(
      from(c in "sales_ticket_resend_challenges", where: c.id == ^challenge.id),
      set: [conversation_id: first.conversation_id, ticket_issue_id: first.ticket_issue_id]
    )

    intent_id =
      begin_resend_intent!(
        first.conversation_id,
        first.order_id,
        first.ticket_issue_id,
        challenge.id
      )

    old_hash = Repo.get!(TicketIssue, first.ticket_issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("invalid resend must not send")
    end)

    assert {:discard, :manual_review} =
             perform_job(SendWhatsAppTicketLinkWorker, %{"ticket_delivery_intent_id" => intent_id})

    assert Repo.get!(TicketIssue, first.ticket_issue_id).delivery_token_hash == old_hash
    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)
  end

  test "resend challenge ticket cross-link fails closed" do
    first = issued_ticket_fixture()
    second = issued_ticket_fixture()

    challenge =
      verified_resend_challenge!(second.conversation_id, second.order_id, second.ticket_issue_id)

    Repo.update_all(
      from(c in "sales_ticket_resend_challenges", where: c.id == ^challenge.id),
      set: [sales_order_id: first.order_id, conversation_id: first.conversation_id]
    )

    intent_id =
      begin_resend_intent!(
        first.conversation_id,
        first.order_id,
        first.ticket_issue_id,
        challenge.id
      )

    old_hash = Repo.get!(TicketIssue, first.ticket_issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("invalid resend must not send")
    end)

    assert {:discard, :manual_review} =
             perform_job(SendWhatsAppTicketLinkWorker, %{"ticket_delivery_intent_id" => intent_id})

    assert Repo.get!(TicketIssue, first.ticket_issue_id).delivery_token_hash == old_hash
    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)
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
                 perform_test_delivery(%{
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

    assert [
             %{
               status: "provider_accepted",
               provider_message_id: "wamid.ticket-out",
               provider_status: "accepted",
               provider_accepted_at: accepted_at,
               sent_at: nil,
               delivery_reason: "initial_ticket_delivery",
               ticket_resend_challenge_id: nil
             }
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select:
                   map(d, [
                     :status,
                     :provider_message_id,
                     :provider_status,
                     :provider_accepted_at,
                     :sent_at,
                     :delivery_reason,
                     :ticket_resend_challenge_id,
                     :within_whatsapp_window,
                     :template_name
                   ])
             )
             |> Enum.map(fn row ->
               assert row.within_whatsapp_window == true
               assert row.template_name == nil

               Map.take(row, [
                 :status,
                 :provider_message_id,
                 :provider_status,
                 :provider_accepted_at,
                 :sent_at,
                 :delivery_reason,
                 :ticket_resend_challenge_id
               ])
             end)

    assert %NaiveDateTime{} = accepted_at
  end

  test "initial delivery records its explicit purpose independently of caller fields" do
    test_pid = self()

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.normal-unknown-reason"}]})
       }}
    end)

    assert :ok =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "delivery_reason" => "bogus"
             })

    assert_received {:whatsapp_request, _request}

    assert [%{delivery_reason: "initial_ticket_delivery", ticket_resend_challenge_id: nil}] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: map(d, [:delivery_reason, :ticket_resend_challenge_id])
             )
  end

  test "verified resend reason without challenge id discards before side effects" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("verified resend reason without challenge id must not send")
    end)

    assert {:discard, :invalid_resend_challenge} =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
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
             perform_test_delivery(%{
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
               status: "provider_accepted",
               provider_message_id: "wamid.ticket-template",
               provider_status: "accepted",
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
                     :provider_status,
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

    assert :ok = perform_test_delivery(args)
    assert_received {:whatsapp_request, _first}
    assert :ok = perform_test_delivery(args)

    refute_received {:whatsapp_request, _duplicate}

    assert {:ok, ttl} =
             Redix.command(FastCheck.Redix, [
               "TTL",
               "fastcheck:whatsapp:dedupe:send_ticket_link:#{conversation_id}:#{issue_id}"
             ])

    assert ttl > 80_000

    assert ["provider_accepted"] =
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
             perform_test_delivery(%{
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

    assert [
             %{
               status: "provider_accepted",
               provider_message_id: "wamid.resend-ticket",
               provider_status: "accepted",
               delivery_reason: "verified_ticket_resend",
               ticket_resend_challenge_id: challenge_id,
               recipient: "+27***4567"
             }
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select:
                   map(d, [
                     :status,
                     :provider_message_id,
                     :provider_status,
                     :delivery_reason,
                     :ticket_resend_challenge_id,
                     :recipient
                   ])
             )

    assert challenge_id == challenge.id
  end

  test "resend challenge id with unknown delivery reason discards before side effects" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)
    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("resend challenge with unknown reason must not send")
    end)

    assert {:discard, :invalid_resend_challenge} =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => challenge.id,
               "delivery_reason" => "bogus"
             })

    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash == old_hash
    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)

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

  test "resend challenge id with nil delivery reason discards before side effects" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)
    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("resend challenge with nil reason must not send")
    end)

    assert {:discard, :invalid_resend_challenge} =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => challenge.id
             })

    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash == old_hash
    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)

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

  test "invalid resend challenge discards before dedupe claim token rotation or send" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    mismatched_conversation_id = insert_worker_conversation!()
    mismatched = verified_resend_challenge!(mismatched_conversation_id, order_id, issue_id)
    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("mismatched resend challenge must not send")
    end)

    assert {:discard, :manual_review} =
             perform_test_delivery(%{
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

    assert {:discard, :manual_review} =
             perform_test_delivery(%{
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
             perform_test_delivery(%{
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
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => challenge.id,
               "delivery_reason" => "verified_ticket_resend"
             })

    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)
  end

  test "resend challenge is not consumed when order is no longer deliverable" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture(order_status: "cancelled")

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)
    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("cancelled order must not be sent")
    end)

    assert {:discard, :ticket_not_deliverable} =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => challenge.id,
               "delivery_reason" => "verified_ticket_resend"
             })

    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash == old_hash
    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)

    assert [] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: d.status
             )
  end

  test "resend challenge is not consumed when secure ticket page is invalid after token rotation" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)
    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Repo.update_all(
      from(a in "attendees",
        join: t in "sales_ticket_issues",
        on: t.attendee_id == a.id,
        where: t.id == ^issue_id
      ),
      set: [scan_eligibility: "not_scannable"]
    )

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("invalid secure ticket page must not be sent")
    end)

    assert {:discard, :ticket_not_deliverable} =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => challenge.id,
               "delivery_reason" => "verified_ticket_resend"
             })

    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash != old_hash
    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)

    assert ["manual_review"] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: d.status
             )
  end

  test "marks DeliveryAttempt failed without storing ticket token when WhatsApp send fails" do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      {:ok,
       %Req.Response{
         status: 429,
         body: Jason.encode!(%{"error" => %{"message" => "rate limited"}})
       }}
    end)

    assert {:error, %{retryable?: true}} =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id
             })

    updated = Repo.get!(TicketIssue, issue_id)

    assert [
             %{
               status: "failed",
               provider_error_message: "whatsapp send failed",
               failure_reason: "safe_retryable_transport_failure",
               failed_at: failed_at,
               provider_status: nil,
               provider_status_at: nil
             }
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select:
                   map(d, [
                     :status,
                     :provider_error_message,
                     :failure_reason,
                     :failed_at,
                     :provider_status,
                     :provider_status_at
                   ])
             )

    assert %NaiveDateTime{} = failed_at

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
                 perform_test_delivery(%{
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
               provider_error_code: "whatsapp_send_requires_review",
               provider_error_message: "whatsapp send requires review",
               failure_reason: "permanent_transport_failure",
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

    %{
      conversation_id: conversation_id,
      order_id: order_id,
      ticket_issue_id: issue_id,
      ticket_delivery_intent_id: intent_id
    } =
      issued_ticket_fixture()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          {:ok,
           %Req.Response{
             status: 429,
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

    assert {:error, %{retryable?: true}} = perform_test_delivery(args)
    assert :ok = perform_test_delivery(args)

    assert_received {:whatsapp_request, _failed_request}
    assert_received {:whatsapp_request, _retry_request}
    refute_received {:whatsapp_request, _extra_request}

    assert [
             {1, "failed", "initial_ticket_delivery", ^intent_id},
             {2, "provider_accepted", "initial_ticket_delivery", ^intent_id}
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 order_by: [asc: d.id],
                 select:
                   {d.attempt_number, d.status, d.delivery_reason, d.ticket_delivery_intent_id}
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
             status: 429,
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

    assert {:error, %{retryable?: true}} = perform_test_delivery(args)
    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)

    assert :ok = perform_test_delivery(args)

    assert %{status: "consumed", consumed_at: consumed_at} =
             resend_challenge_snapshot(challenge.id)

    assert consumed_at

    assert_received {:whatsapp_request, _failed_request}
    assert_received {:whatsapp_request, _retry_request}
  end

  test "exhausted safe transport retries fail the attempt and close the intent" do
    %{ticket_delivery_intent_id: intent_id} = issued_ticket_fixture()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      {:ok,
       %Req.Response{
         status: 429,
         body: Jason.encode!(%{"error" => %{"message" => "retry later"}})
       }}
    end)

    assert {:discard, :manual_review} =
             perform_job(
               SendWhatsAppTicketLinkWorker,
               %{"ticket_delivery_intent_id" => intent_id},
               attempt: 5,
               max_attempts: 5
             )

    assert %{status: "manual_review", failure_reason: "safe_transport_retries_exhausted"} =
             Repo.one!(
               from i in "sales_ticket_delivery_intents",
                 where: i.id == ^intent_id,
                 select: map(i, [:status, :failure_reason])
             )

    assert [%{status: "failed", attempt_number: 1}] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_delivery_intent_id == ^intent_id,
                 select: map(d, [:status, :attempt_number])
             )

    refute_received {:whatsapp_request, _second_request}
  end

  test "provider acceptance stays durable when challenge consumption already happened" do
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

    assert :ok = perform_test_delivery(args)

    assert :ok = perform_test_delivery(args)

    assert_received {:whatsapp_request, _request}
    refute_received {:whatsapp_request, _duplicate}

    challenge_dedupe_key =
      "fastcheck:whatsapp:dedupe:send_ticket_link:" <>
        "#{conversation_id}:#{issue_id}:challenge:#{challenge.id}"

    assert {:ok, ttl} = Redix.command(FastCheck.Redix, ["TTL", challenge_dedupe_key])

    assert ttl > 0
  end

  test "marks ambiguous 5xx, timeout, and missing WAMID ticket responses for manual review, holds dedupe",
       %{} do
    for provider_result <- [
          {:http, 500},
          {:http, 503},
          :timeout,
          :missing_wamid
        ] do
      %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
        issued_ticket_fixture()

      request_fun =
        case provider_result do
          {:http, status} ->
            fn _request ->
              {:ok,
               %Req.Response{
                 status: status,
                 body: Jason.encode!(%{"error" => %{"message" => "upstream issue"}})
               }}
            end

          :timeout ->
            fn _request -> {:error, %Req.TransportError{reason: :timeout}} end

          :missing_wamid ->
            fn _request ->
              {:ok,
               %Req.Response{
                 status: 200,
                 body: Jason.encode!(%{"messages" => []})
               }}
            end
        end

      Application.put_env(:fastcheck, :whatsapp_request_fun, request_fun)

      assert {:discard, :manual_review} =
               perform_test_delivery(%{
                 "conversation_id" => conversation_id,
                 "sales_order_id" => order_id,
                 "ticket_issue_id" => issue_id
               })

      assert [
               %{
                 status: "manual_review",
                 failure_reason: "ambiguous_transport_outcome",
                 fallback_channel: "manual_review",
                 provider_status: nil,
                 provider_status_at: nil
               }
             ] =
               Repo.all(
                 from d in "sales_delivery_attempts",
                   where: d.ticket_issue_id == ^issue_id,
                   select:
                     map(d, [
                       :status,
                       :failure_reason,
                       :fallback_channel,
                       :provider_status,
                       :provider_status_at
                     ])
               )

      assert {:ok, ttl} =
               Redix.command(FastCheck.Redix, [
                 "TTL",
                 "fastcheck:whatsapp:dedupe:send_ticket_link:#{conversation_id}:#{issue_id}"
               ])

      assert ttl > 0
    end
  end

  test "ambiguous ticket delivery blocks re-send after Redis expiry and keeps token stable",
       %{} do
    test_pid = self()

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 503,
         body: Jason.encode!(%{"error" => %{"message" => "upstream overload"}})
       }}
    end)

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id
    }

    assert {:discard, :manual_review} = perform_test_delivery(args)
    assert_received {:whatsapp_request, _initial_request}

    token_after_attempt = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    # Simulate Redis dedupe expiry by deleting key
    dedupe_key = "fastcheck:whatsapp:dedupe:send_ticket_link:#{conversation_id}:#{issue_id}"
    {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", dedupe_key])

    # Re-executing the job is blocked by DB guard with zero Meta calls and no token rotation
    assert {:discard, :manual_review} = perform_test_delivery(args)
    refute_received {:whatsapp_request, _second_request}

    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash == token_after_attempt

    assert 1 =
             Repo.one!(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: count(d.id)
             )
  end

  test "crash window: unresolved dispatching blocks ticket re-run with zero Meta calls and no rotation",
       %{} do
    test_pid = self()

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.ticket-crash"}]})
       }}
    end)

    {:ok, queued} =
      DeliveryAttempt
      |> Changeset.for_create(
        :create_queued,
        %{
          sales_order_id: order_id,
          ticket_issue_id: issue_id,
          ticket_delivery_intent_id: initial_intent_id_for_issue!(issue_id),
          channel: "whatsapp",
          provider: "meta",
          recipient: "27***4567",
          delivery_reason: "initial_ticket_delivery",
          attempt_number: 1,
          correlation_id: "whatsapp-ticket-link-#{issue_id}"
        },
        actor: system_actor()
      )
      |> Ash.create(authorize?: false)

    {:ok, dispatching} =
      queued
      |> Changeset.for_update(:mark_dispatching, %{}, actor: system_actor())
      |> Ash.update(authorize?: false)

    Repo.query!(
      "UPDATE sales_delivery_attempts SET updated_at = now() - interval '5 minutes' WHERE id = $1",
      [dispatching.id]
    )

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id
    }

    assert {:discard, :manual_review} = perform_test_delivery(args)
    refute_received {:whatsapp_request, _meta_request}

    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash == old_hash

    assert [
             %{status: "manual_review", failure_reason: "ambiguous_transport_outcome"}
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: map(d, [:status, :failure_reason])
             )
  end

  test "concurrent duplicate worker leaves the live dispatch intact until provider acceptance" do
    parent = self()
    %{ticket_delivery_intent_id: intent_id} = issued_ticket_fixture()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(parent, {:whatsapp_request_started, request})

      receive do
        :release_provider_response ->
          {:ok,
           %Req.Response{
             status: 200,
             body: Jason.encode!(%{"messages" => [%{"id" => "wamid.concurrent-accept"}]})
           }}
      end
    end)

    task =
      Task.async(fn ->
        send(parent, {:send_worker_ready, self()})

        receive do
          :start_send_worker ->
            perform_job(SendWhatsAppTicketLinkWorker, %{"ticket_delivery_intent_id" => intent_id})
        end
      end)

    assert_receive {:send_worker_ready, task_pid}
    assert task_pid == task.pid
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :start_send_worker)

    case Task.yield(task, 0) do
      {:ok, result} -> flunk("worker returned before provider call: #{inspect(result)}")
      {:exit, reason} -> flunk("worker exited before provider call: #{inspect(reason)}")
      nil -> :ok
    end

    assert_receive {:whatsapp_request_started, _request}, 5_000

    assert {:error, %{retryable?: true, classification: "dispatch_in_progress"}} =
             perform_job(SendWhatsAppTicketLinkWorker, %{"ticket_delivery_intent_id" => intent_id})

    assert %{status: "queued"} =
             Repo.one!(
               from i in "sales_ticket_delivery_intents",
                 where: i.id == ^intent_id,
                 select: map(i, [:status])
             )

    assert [%{status: "dispatching", attempt_number: 1}] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_delivery_intent_id == ^intent_id,
                 select: map(d, [:status, :attempt_number])
             )

    refute_received {:whatsapp_request_started, _duplicate_request}

    assert {:discard, :manual_review} =
             perform_job(
               SendWhatsAppTicketLinkWorker,
               %{"ticket_delivery_intent_id" => intent_id},
               attempt: 5,
               max_attempts: 5
             )

    send(task.pid, :release_provider_response)

    assert :ok = Task.await(task, 5_000)

    assert %{status: "provider_accepted"} =
             Repo.one!(
               from i in "sales_ticket_delivery_intents",
                 where: i.id == ^intent_id,
                 select: map(i, [:status])
             )

    assert [%{status: "provider_accepted", attempt_number: 1}] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_delivery_intent_id == ^intent_id,
                 select: map(d, [:status, :attempt_number])
             )
  end

  test "verified resend ambiguous outcome holds challenge; same challenge blocked; new challenge sends",
       %{} do
    test_pid = self()
    counter = :counters.new(1, [])
    request_count = :counters.new(1, [])

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
             status: 503,
             body: Jason.encode!(%{"error" => %{"message" => "upstream overload"}})
           }}

        _ ->
          {:ok,
           %Req.Response{
             status: 200,
             body: Jason.encode!(%{"messages" => [%{"id" => "wamid.resend-other-challenge"}]})
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

    assert {:discard, :manual_review} = perform_test_delivery(args)
    assert_received {:whatsapp_request, _initial_request}
    :counters.add(request_count, 1, 1)

    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)

    challenge_dedupe_key =
      Dedupe.send_ticket_link_identity(conversation_id, issue_id, challenge.id)

    {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", challenge_dedupe_key])

    # Same verified challenge re-executes: DB guard blocks before any Meta call
    assert {:discard, :manual_review} = perform_test_delivery(args)
    refute_received {:whatsapp_request, _blocked_request}
    assert %{status: "verified", consumed_at: nil} = resend_challenge_snapshot(challenge.id)

    # The database intent remains authoritative when its Redis hint is absent.

    # A new independently verified challenge is allowed WITHOUT deleting the old challenge key
    new_challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)

    assert :ok =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => new_challenge.id,
               "delivery_reason" => "verified_ticket_resend"
             })

    assert_received {:whatsapp_request, _new_challenge_request}
    :counters.add(request_count, 1, 1)

    assert %{status: "consumed", consumed_at: consumed_at} =
             resend_challenge_snapshot(new_challenge.id)

    assert consumed_at

    # The old Redis hint remains absent; its durable intent blocks the old challenge.
    assert {:ok, ttl} =
             Redix.command(FastCheck.Redix, ["TTL", challenge_dedupe_key])

    assert ttl == -2

    assert :counters.get(request_count, 1) == 2
  end

  test "accepted initial intent stays suppressed after Redis expiry while verified resend is independent",
       %{} do
    test_pid = self()
    counter = :counters.new(1, [])

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})
      :counters.add(counter, 1, 1)

      {:ok,
       %Req.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "messages" => [%{"id" => "wamid.ticket-#{:counters.get(counter, 1)}"}]
           })
       }}
    end)

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id
    }

    assert :ok = perform_test_delivery(args)
    assert_received {:whatsapp_request, _first}

    # The initial intent remains satisfied after its Redis hint expires.
    dedupe_key = "fastcheck:whatsapp:dedupe:send_ticket_link:#{conversation_id}:#{issue_id}"
    {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", dedupe_key])

    assert :ok = perform_test_delivery(args)

    refute_received {:whatsapp_request, _duplicate_initial}

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)

    assert :ok =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => challenge.id,
               "delivery_reason" => "verified_ticket_resend"
             })

    assert_received {:whatsapp_request, _resend}
    refute_received {:whatsapp_request, _third}

    assert %{status: "consumed", consumed_at: consumed_at} =
             resend_challenge_snapshot(challenge.id)

    assert consumed_at

    assert [
             {"provider_accepted", "initial_ticket_delivery"},
             {"provider_accepted", "verified_ticket_resend"}
           ] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 order_by: [asc: d.id],
                 select: {d.status, d.delivery_reason}
             )
  end

  test "duplicate verified resend enqueue is scoped by challenge id in Oban uniqueness", %{} do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge_a = verified_resend_challenge!(conversation_id, order_id, issue_id)
    challenge_b = verified_resend_challenge!(conversation_id, order_id, issue_id)

    intent_a = resend_delivery_intent!(conversation_id, order_id, issue_id, challenge_a.id)
    intent_b = resend_delivery_intent!(conversation_id, order_id, issue_id, challenge_b.id)
    args_a = %{"ticket_delivery_intent_id" => intent_a}
    args_b = %{"ticket_delivery_intent_id" => intent_b}

    assert {:ok, %Oban.Job{conflict?: false}} =
             Oban.insert(SendWhatsAppTicketLinkWorker.new(args_a))

    assert {:ok, %Oban.Job{conflict?: true}} =
             Oban.insert(SendWhatsAppTicketLinkWorker.new(args_a))

    assert {:ok, %Oban.Job{conflict?: false}} =
             Oban.insert(SendWhatsAppTicketLinkWorker.new(args_b))
  end

  test "same verified challenge never calls Meta again after provider acceptance when consume was lost",
       %{} do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)
    intent_id = resend_delivery_intent!(conversation_id, order_id, issue_id, challenge.id)
    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    # Simulate a past execution that reached provider acceptance and crashed before consuming
    {:ok, accepted} =
      DeliveryAttempt
      |> Changeset.for_create(
        :create_queued,
        %{
          sales_order_id: order_id,
          ticket_issue_id: issue_id,
          ticket_delivery_intent_id: intent_id,
          ticket_resend_challenge_id: challenge.id,
          channel: "whatsapp",
          provider: "meta",
          recipient: "+27***4567",
          delivery_reason: "verified_ticket_resend",
          attempt_number: 1,
          correlation_id: "whatsapp-ticket-link-#{issue_id}"
        },
        actor: system_actor()
      )
      |> Ash.create(authorize?: false)

    {:ok, dispatchable} =
      accepted
      |> Changeset.for_update(:mark_dispatching, %{}, actor: system_actor())
      |> Ash.update(authorize?: false)

    {:ok, _provider_accepted} =
      dispatchable
      |> Changeset.for_update(
        :mark_provider_accepted,
        %{
          provider_message_id: "wamid.accepted-before-crash",
          provider_accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        actor: system_actor()
      )
      |> Ash.update(authorize?: false)

    # Model Redis dedupe expiry between the crashed run and the retry
    challenge_dedupe_key =
      Dedupe.send_ticket_link_identity(conversation_id, issue_id, challenge.id)

    {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", challenge_dedupe_key])

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id,
      "ticket_resend_challenge_id" => challenge.id,
      "delivery_reason" => "verified_ticket_resend"
    }

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("same verified challenge with a prior provider acceptance must not call Meta again")
    end)

    assert :ok = perform_test_delivery(args)

    refute_received {:whatsapp_request, _meta_request}

    # No token rotation happened
    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash == old_hash

    # The previously-lost consume step is recovered idempotently
    assert %{status: "consumed", consumed_at: consumed_at} =
             resend_challenge_snapshot(challenge.id)

    assert consumed_at

    # No second DeliveryAttempt was created
    assert 1 =
             Repo.one!(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: count(d.id)
             )
  end

  test "same verified challenge stays suppressed after a provider failure post-acceptance", %{} do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)
    intent_id = resend_delivery_intent!(conversation_id, order_id, issue_id, challenge.id)
    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    # Simulate a past execution that reached provider acceptance and later failed via the
    # provider-status reconciliation path (H01A equivalent) before the consume step ran.
    {:ok, queued} =
      DeliveryAttempt
      |> Changeset.for_create(
        :create_queued,
        %{
          sales_order_id: order_id,
          ticket_issue_id: issue_id,
          ticket_delivery_intent_id: intent_id,
          ticket_resend_challenge_id: challenge.id,
          channel: "whatsapp",
          provider: "meta",
          recipient: "+27***4567",
          delivery_reason: "verified_ticket_resend",
          attempt_number: 1,
          correlation_id: "whatsapp-ticket-link-#{issue_id}"
        },
        actor: system_actor()
      )
      |> Ash.create(authorize?: false)

    {:ok, dispatching} =
      queued
      |> Changeset.for_update(:mark_dispatching, %{}, actor: system_actor())
      |> Ash.update(authorize?: false)

    {:ok, accepted} =
      dispatching
      |> Changeset.for_update(
        :mark_provider_accepted,
        %{
          provider_message_id: "wamid.accepted-then-provider-failed",
          provider_accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        actor: system_actor()
      )
      |> Ash.update(authorize?: false)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, failed} =
      accepted
      |> Changeset.for_update(
        :mark_provider_failed,
        %{provider_error_code: "131047", failed_at: now},
        actor: system_actor()
      )
      |> Ash.update(authorize?: false)

    assert failed.status == "failed"
    assert failed.failure_reason == "provider_status_failed"
    assert failed.provider_message_id == "wamid.accepted-then-provider-failed"

    # Model Redis dedupe expiry between the crashed run and the retry
    challenge_dedupe_key =
      Dedupe.send_ticket_link_identity(conversation_id, issue_id, challenge.id)

    {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", challenge_dedupe_key])

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id,
      "ticket_resend_challenge_id" => challenge.id,
      "delivery_reason" => "verified_ticket_resend"
    }

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("same verified challenge with a prior provider acceptance must not call Meta again")
    end)

    assert :ok = perform_test_delivery(args)

    refute_received {:whatsapp_request, _meta_request}

    # No token rotation happened
    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash == old_hash

    # The never-consumed challenge is recovered idempotently
    assert %{status: "consumed", consumed_at: consumed_at} =
             resend_challenge_snapshot(challenge.id)

    assert consumed_at

    # No second DeliveryAttempt was created
    assert 1 =
             Repo.one!(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: count(d.id)
             )
  end

  test "same verified challenge stays suppressed after cancelling a provider-accepted attempt",
       %{} do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)
    intent_id = resend_delivery_intent!(conversation_id, order_id, issue_id, challenge.id)
    old_hash = Repo.get!(TicketIssue, issue_id).delivery_token_hash

    # Simulate a past execution that reached provider acceptance and was later cancelled by an
    # operator before the consume step ran.
    {:ok, queued} =
      DeliveryAttempt
      |> Changeset.for_create(
        :create_queued,
        %{
          sales_order_id: order_id,
          ticket_issue_id: issue_id,
          ticket_delivery_intent_id: intent_id,
          ticket_resend_challenge_id: challenge.id,
          channel: "whatsapp",
          provider: "meta",
          recipient: "+27***4567",
          delivery_reason: "verified_ticket_resend",
          attempt_number: 1,
          correlation_id: "whatsapp-ticket-link-#{issue_id}"
        },
        actor: system_actor()
      )
      |> Ash.create(authorize?: false)

    {:ok, dispatching} =
      queued
      |> Changeset.for_update(:mark_dispatching, %{}, actor: system_actor())
      |> Ash.update(authorize?: false)

    {:ok, accepted} =
      dispatching
      |> Changeset.for_update(
        :mark_provider_accepted,
        %{
          provider_message_id: "wamid.accepted-then-cancelled",
          provider_accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        actor: system_actor()
      )
      |> Ash.update(authorize?: false)

    {:ok, cancelled} =
      accepted
      |> Changeset.for_update(:mark_cancelled, %{failure_reason: "operator_cancelled"},
        actor: system_actor()
      )
      |> Ash.update(authorize?: false)

    assert cancelled.status == "cancelled"
    assert cancelled.provider_message_id == "wamid.accepted-then-cancelled"

    # Model Redis dedupe expiry between the crashed run and the retry
    challenge_dedupe_key =
      Dedupe.send_ticket_link_identity(conversation_id, issue_id, challenge.id)

    {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", challenge_dedupe_key])

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id,
      "ticket_resend_challenge_id" => challenge.id,
      "delivery_reason" => "verified_ticket_resend"
    }

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("same verified challenge with a prior provider acceptance must not call Meta again")
    end)

    assert :ok = perform_test_delivery(args)

    refute_received {:whatsapp_request, _meta_request}

    # No token rotation happened
    assert Repo.get!(TicketIssue, issue_id).delivery_token_hash == old_hash

    # The never-consumed challenge is recovered idempotently
    assert %{status: "consumed", consumed_at: consumed_at} =
             resend_challenge_snapshot(challenge.id)

    assert consumed_at

    # No second DeliveryAttempt was created
    assert 1 =
             Repo.one!(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: count(d.id)
             )
  end

  test "a local rate_limited failure without a WAMID keeps the verified resend challenge spendable",
       %{} do
    test_pid = self()

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)

    # Simulate a past run that failed locally (Meta 429) before any provider acceptance:
    # guessed-safe, so the challenge must remain spendable for a retry.
    {:ok, queued} =
      DeliveryAttempt
      |> Changeset.for_create(
        :create_queued,
        %{
          sales_order_id: order_id,
          ticket_issue_id: issue_id,
          ticket_resend_challenge_id: challenge.id,
          channel: "whatsapp",
          provider: "meta",
          recipient: "+27***4567",
          delivery_reason: "verified_ticket_resend",
          attempt_number: 1,
          correlation_id: "whatsapp-ticket-link-#{issue_id}"
        },
        actor: system_actor()
      )
      |> Ash.create(authorize?: false)

    {:ok, dispatching} =
      queued
      |> Changeset.for_update(:mark_dispatching, %{}, actor: system_actor())
      |> Ash.update(authorize?: false)

    {:ok, failed} =
      dispatching
      |> Changeset.for_update(
        :mark_failed,
        %{
          provider_error_code: "130429",
          provider_error_message: "user is sending too many messages",
          failure_reason: "rate_limited"
        },
        actor: system_actor()
      )
      |> Ash.update(authorize?: false)

    assert failed.status == "failed"
    assert failed.failure_reason == "rate_limited"
    assert is_nil(failed.provider_message_id)
    assert is_nil(failed.provider_status)

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.post-429-retry"}]})
       }}
    end)

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id,
      "ticket_resend_challenge_id" => challenge.id,
      "delivery_reason" => "verified_ticket_resend"
    }

    assert :ok = perform_test_delivery(args)

    assert_received {:whatsapp_request, _retry_request}

    # The challenge is consumed by the successful retry
    assert %{status: "consumed", consumed_at: consumed_at} =
             resend_challenge_snapshot(challenge.id)

    assert consumed_at

    # Exactly one new DeliveryAttempt on top of the failed seed
    assert 2 =
             Repo.one!(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: count(d.id)
             )
  end

  test "provider-accepted challenge A does not suppress an independent challenge B resend", %{} do
    test_pid = self()
    counter = :counters.new(1, [])

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge_a = verified_resend_challenge!(conversation_id, order_id, issue_id)
    challenge_b = verified_resend_challenge!(conversation_id, order_id, issue_id)

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})
      :counters.add(counter, 1, 1)

      {:ok,
       %Req.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "messages" => [%{"id" => "wamid.resend-#{:counters.get(counter, 1)}"}]
           })
       }}
    end)

    base = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id,
      "delivery_reason" => "verified_ticket_resend"
    }

    assert :ok =
             perform_test_delivery(Map.put(base, "ticket_resend_challenge_id", challenge_a.id))

    assert :ok =
             perform_test_delivery(Map.put(base, "ticket_resend_challenge_id", challenge_b.id))

    assert_received {:whatsapp_request, _a_request}
    assert_received {:whatsapp_request, _b_request}
    refute_received {:whatsapp_request, _extra_request}

    assert %{status: "consumed"} = resend_challenge_snapshot(challenge_a.id)
    assert %{status: "consumed"} = resend_challenge_snapshot(challenge_b.id)

    key_a = Dedupe.send_ticket_link_identity(conversation_id, issue_id, challenge_a.id)
    key_b = Dedupe.send_ticket_link_identity(conversation_id, issue_id, challenge_b.id)

    assert {:ok, ttl_a} = Redix.command(FastCheck.Redix, ["TTL", key_a])
    assert ttl_a > 0

    assert {:ok, ttl_b} = Redix.command(FastCheck.Redix, ["TTL", key_b])
    assert ttl_b > 0
  end

  test "verified resend retry within the dedupe TTL is suppressed as an idempotent no-op", %{} do
    test_pid = self()
    counter = :counters.new(1, [])

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})
      :counters.add(counter, 1, 1)

      {:ok, %Req.Response{status: 503, body: "server error"}}
    end)

    args = %{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => issue_id,
      "ticket_resend_challenge_id" => challenge.id,
      "delivery_reason" => "verified_ticket_resend"
    }

    # First run is ambiguous: manual_review outcome, challenge NOT consumed, Redis hold retained
    assert {:discard, :manual_review} = perform_test_delivery(args)
    assert_received {:whatsapp_request, _first_request}

    # A retry sees the durable manual-review state and does not send again.
    assert {:discard, :manual_review} = perform_test_delivery(args)
    refute_received {:whatsapp_request, _second_request}
    assert :counters.get(counter, 1) == 1

    assert %{status: "verified"} = resend_challenge_snapshot(challenge.id)

    assert 1 =
             Repo.one!(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: count(d.id)
             )
  end

  test "non-Meta and non-WhatsApp delivery rows cannot block a WhatsApp ticket send", %{} do
    test_pid = self()

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    challenge = verified_resend_challenge!(conversation_id, order_id, issue_id)

    # An ambiguity row for the ticket issue that is NOT a Meta WhatsApp attempt
    seed_delivery_attempt!(order_id, issue_id, %{
      channel: "email",
      provider: "braintree",
      delivery_reason: nil,
      status: "manual_review"
    })

    # A provider-accepted row for the SAME resend challenge that is NOT a Meta WhatsApp attempt
    seed_delivery_attempt!(order_id, issue_id, %{
      ticket_resend_challenge_id: challenge.id,
      channel: "email",
      provider: "braintree",
      delivery_reason: "verified_ticket_resend",
      provider_message_id: "external.provider-message-1",
      status: "provider_accepted"
    })

    counter = :counters.new(1, [])

    Application.put_env(
      :fastcheck,
      :whatsapp_request_fun,
      fn _request ->
        send(test_pid, {:whatsapp_request, :request})

        :counters.add(counter, 1, 1)

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "messages" => [%{"id" => "wamid.not-blocked-#{:counters.get(counter, 1)}"}]
             })
         }}
      end
    )

    assert :ok =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id
             })

    assert :ok =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id,
               "ticket_resend_challenge_id" => challenge.id,
               "delivery_reason" => "verified_ticket_resend"
             })

    assert_received {:whatsapp_request, _ordinary_request}
    assert_received {:whatsapp_request, _resend_request}
  end

  test "ambiguity guard stays bounded to blocking statuses across attempt history", %{} do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    # Accepted Meta evidence recovers the intent after a lost intent-state write.
    for attempt_number <- 1..10 do
      seed_delivery_attempt!(order_id, issue_id, %{
        status: "provider_accepted",
        attempt_number: attempt_number,
        provider_message_id: "wamid.history-#{attempt_number}"
      })
    end

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("durable acceptance evidence must prevent another Meta send")
    end)

    assert :ok =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id
             })

    refute_received {:whatsapp_request, _fresh_request}
  end

  test "ambiguity guard detects a blocking row among non-blocking history", %{} do
    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue_id} =
      issued_ticket_fixture()

    for attempt_number <- 1..10 do
      seed_delivery_attempt!(order_id, issue_id, %{
        status: "provider_accepted",
        attempt_number: attempt_number,
        provider_message_id: "wamid.history-#{attempt_number}"
      })
    end

    seed_delivery_attempt!(order_id, issue_id, %{status: "manual_review", attempt_number: 11})

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      flunk("a manual_review row in the history must block a second automatic send")
    end)

    assert :ok =
             perform_test_delivery(%{
               "conversation_id" => conversation_id,
               "sales_order_id" => order_id,
               "ticket_issue_id" => issue_id
             })

    refute_received {:whatsapp_request, _request}
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
    {order_id, order_line_id} = insert_order_with_line!(event.id, opts)

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

    Repo.update_all(
      from(o in "sales_orders", where: o.id == ^order_id),
      set: [sales_conversation_id: conversation_id]
    )

    intent_id = initial_delivery_intent!(conversation_id, order_id, issue.id)

    %{
      conversation_id: conversation_id,
      order_id: order_id,
      ticket_issue_id: issue.id,
      ticket_delivery_intent_id: intent_id
    }
  end

  # The older behavioral cases pass fixture hints here; only the durable ID is
  # handed to the actual worker. Production jobs are inserted with this exact
  # one-key shape by TicketDeliveryCoordinator and ResendDeliveryFlow.
  defp perform_test_delivery(%{"ticket_delivery_intent_id" => id}),
    do: perform_job(SendWhatsAppTicketLinkWorker, %{"ticket_delivery_intent_id" => id})

  defp perform_test_delivery(args) when is_map(args) do
    challenge_id = Map.get(args, "ticket_resend_challenge_id")
    reason = Map.get(args, "delivery_reason")

    cond do
      reason == "verified_ticket_resend" and not is_integer(challenge_id) ->
        {:discard, :invalid_resend_challenge}

      is_integer(challenge_id) and reason != "verified_ticket_resend" ->
        {:discard, :invalid_resend_challenge}

      is_integer(challenge_id) ->
        intent_id =
          resend_delivery_intent!(
            Map.get(args, "conversation_id"),
            Map.get(args, "sales_order_id"),
            Map.get(args, "ticket_issue_id"),
            challenge_id
          )

        perform_test_delivery(%{"ticket_delivery_intent_id" => intent_id})

      true ->
        issue_id = Map.fetch!(args, "ticket_issue_id")
        intent_id = initial_intent_id_for_issue!(issue_id)
        perform_test_delivery(%{"ticket_delivery_intent_id" => intent_id})
    end
  end

  defp initial_delivery_intent!(conversation_id, order_id, issue_id) do
    attrs = %{
      sales_order_id: order_id,
      ticket_issue_id: issue_id,
      conversation_id: conversation_id,
      purpose: "initial_ticket_delivery"
    }

    assert {:ok, intent} =
             TicketDeliveryIntent
             |> Changeset.for_create(:create_queued, attrs, actor: system_actor())
             |> Ash.create(authorize?: false)

    intent.id
  end

  defp initial_intent_id_for_issue!(issue_id) do
    Repo.one!(
      from i in "sales_ticket_delivery_intents",
        where: i.ticket_issue_id == ^issue_id and i.purpose == "initial_ticket_delivery",
        select: i.id
    )
  end

  defp resend_delivery_intent!(conversation_id, order_id, issue_id, challenge_id) do
    existing_id =
      Repo.one(
        from i in "sales_ticket_delivery_intents",
          where: i.ticket_resend_challenge_id == ^challenge_id,
          select: i.id
      )

    existing_id ||
      begin_resend_intent!(conversation_id, order_id, issue_id, challenge_id)
  end

  defp begin_resend_intent!(conversation_id, order_id, issue_id, challenge_id) do
    attrs = %{
      sales_order_id: order_id,
      ticket_issue_id: issue_id,
      conversation_id: conversation_id,
      ticket_resend_challenge_id: challenge_id,
      purpose: "verified_ticket_resend"
    }

    assert {:ok, intent} =
             TicketDeliveryIntent
             |> Changeset.for_create(:create_queued, attrs, actor: system_actor())
             |> Ash.create(authorize?: false)

    intent.id
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

  defp seed_delivery_attempt!(order_id, ticket_issue_id, opts) do
    intent_id =
      Map.get(opts, :ticket_delivery_intent_id) ||
        case Map.get(opts, :ticket_resend_challenge_id) do
          challenge_id when is_integer(challenge_id) ->
            Repo.one(
              from i in "sales_ticket_delivery_intents",
                where: i.ticket_resend_challenge_id == ^challenge_id,
                select: i.id
            ) ||
              begin_resend_intent!(
                Repo.one!(
                  from c in "sales_ticket_resend_challenges",
                    where: c.id == ^challenge_id,
                    select: c.conversation_id
                ),
                order_id,
                ticket_issue_id,
                challenge_id
              )

          _no_challenge ->
            initial_intent_id_for_issue!(ticket_issue_id)
        end

    attrs = %{
      sales_order_id: order_id,
      ticket_issue_id: ticket_issue_id,
      ticket_delivery_intent_id: intent_id,
      ticket_resend_challenge_id: Map.get(opts, :ticket_resend_challenge_id),
      channel: Map.get(opts, :channel, "whatsapp"),
      provider: Map.get(opts, :provider, "meta"),
      recipient: "+27***4567",
      delivery_reason: Map.get(opts, :delivery_reason),
      attempt_number: Map.get(opts, :attempt_number) || 1,
      correlation_id: "seed-#{System.unique_integer([:positive])}"
    }

    assert {:ok, queued} =
             DeliveryAttempt
             |> Changeset.for_create(:create_queued, attrs, actor: system_actor())
             |> Ash.create(authorize?: false)

    {:ok, dispatching} =
      queued
      |> Changeset.for_update(:mark_dispatching, %{}, actor: system_actor())
      |> Ash.update(authorize?: false)

    case Map.get(opts, :status, "dispatching") do
      "provider_accepted" ->
        {:ok, _accepted} =
          dispatching
          |> Changeset.for_update(
            :mark_provider_accepted,
            %{
              provider_message_id: Map.get(opts, :provider_message_id, "wamid.seeded"),
              provider_accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
            },
            actor: system_actor()
          )
          |> Ash.update(authorize?: false)

      "manual_review" ->
        {:ok, _reviewed} =
          dispatching
          |> Changeset.for_update(
            :mark_manual_review,
            %{
              provider_error_code: "timeout",
              provider_error_message: "whatsapp send failed",
              failure_reason: "ambiguous_transport_outcome",
              fallback_channel: "manual_review"
            },
            actor: system_actor()
          )
          |> Ash.update(authorize?: false)
    end
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

  defp insert_order_with_line!(event_id, opts) do
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
           $3, 100, 'ZAR', now(), now(), now())
        RETURNING id
        """,
        [
          "FC-#{System.unique_integer([:positive])}",
          event_id,
          Keyword.get(opts, :order_status, "ticket_issued")
        ]
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
