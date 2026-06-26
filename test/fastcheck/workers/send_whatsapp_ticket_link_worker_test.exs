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
  alias FastCheck.Tickets.{DeliveryToken, TokenHash}
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
    body = request.options.json["text"]["body"]
    assert body =~ "/t/"
    refute body =~ "QR"

    updated = Repo.get!(TicketIssue, issue_id)
    assert updated.delivery_token_hash != old_hash
    refute body =~ updated.delivery_token_hash
    refute log =~ updated.delivery_token_hash

    token = body |> String.split("/t/") |> List.last() |> String.split() |> hd()
    assert TokenHash.verify(token, updated.delivery_token_hash, :delivery)

    assert [%{status: "sent", provider_message_id: "wamid.ticket-out"}] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: map(d, [:status, :provider_message_id])
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

    assert ["sent"] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue_id,
                 select: d.status
             )
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

    %{rows: [[conversation_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES
          ('+27821234567', '27821234567', 'af', 'ticket_issued', $1, false, now(), now())
        RETURNING id
        """,
        [%{"sales_order_id" => order_id}]
      )

    %{conversation_id: conversation_id, order_id: order_id, ticket_issue_id: issue.id}
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
