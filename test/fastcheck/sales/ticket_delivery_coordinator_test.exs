defmodule FastCheck.Sales.TicketDeliveryCoordinatorTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import FastCheck.TicketResendFixtures

  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketDeliveryCoordinator
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker
  alias FastCheck.Workers.TicketDeliveryCoordinatorWorker

  test "coordinator worker accepts only the durable sales order ID" do
    assert {:discard, :invalid_args} =
             perform_job(TicketDeliveryCoordinatorWorker, %{
               "sales_order_id" => 1,
               "conversation_id" => 2
             })
  end

  test "incomplete coordinator jobs deduplicate for the same order" do
    args = %{"sales_order_id" => System.unique_integer([:positive])}

    assert {:ok, first} = TicketDeliveryCoordinatorWorker.new(args) |> Oban.insert()
    assert first.conflict? == false

    assert {:ok, duplicate} = TicketDeliveryCoordinatorWorker.new(args) |> Oban.insert()
    assert duplicate.conflict? == true

    assert length(all_enqueued(worker: TicketDeliveryCoordinatorWorker, args: args)) == 1
  end

  test "queues one durable initial intent for every valid issued ticket" do
    candidate = issued_ticket_candidate!()
    conversation_id = insert_conversation!()
    bind_order_to_conversation!(candidate.sales_order_id, conversation_id)

    assert {:ok, %{intent_count: 1}} =
             TicketDeliveryCoordinator.coordinate(candidate.sales_order_id)

    assert [%{id: intent_id, purpose: "initial_ticket_delivery", status: "queued"}] =
             intents_for_order(candidate.sales_order_id)

    assert_enqueued(
      worker: SendWhatsAppTicketLinkWorker,
      args: %{"ticket_delivery_intent_id" => intent_id}
    )
  end

  test "duplicate coordinator execution reuses each initial intent" do
    candidate = issued_ticket_candidate!()
    conversation_id = insert_conversation!()
    bind_order_to_conversation!(candidate.sales_order_id, conversation_id)

    assert {:ok, %{intent_count: 1}} =
             TicketDeliveryCoordinator.coordinate(candidate.sales_order_id)

    assert {:ok, %{intent_count: 1}} =
             TicketDeliveryCoordinator.coordinate(candidate.sales_order_id)

    assert length(intents_for_order(candidate.sales_order_id)) == 1

    assert [job] =
             all_enqueued(
               worker: SendWhatsAppTicketLinkWorker,
               args: %{
                 "ticket_delivery_intent_id" => hd(intents_for_order(candidate.sales_order_id)).id
               }
             )

    assert job.args == %{
             "ticket_delivery_intent_id" => hd(intents_for_order(candidate.sales_order_id)).id
           }
  end

  test "paginates beyond 50 issues and queues every durable intent" do
    candidate = issued_ticket_candidate!()
    conversation_id = insert_conversation!()
    bind_order_to_conversation!(candidate.sales_order_id, conversation_id)
    add_issued_units!(candidate, 60)

    assert {:ok, %{intent_count: 60}} =
             TicketDeliveryCoordinator.coordinate(candidate.sales_order_id)

    assert 60 ==
             Repo.one!(
               from i in "sales_ticket_delivery_intents",
                 where:
                   i.sales_order_id == ^candidate.sales_order_id and
                     i.purpose == "initial_ticket_delivery",
                 select: count(i.id)
             )

    assert length(all_enqueued(worker: SendWhatsAppTicketLinkWorker)) == 60

    issue_ids =
      Repo.all(
        from i in "sales_ticket_delivery_intents",
          where: i.sales_order_id == ^candidate.sales_order_id,
          select: i.ticket_issue_id
      )

    assert length(issue_ids) == 60
    assert length(Enum.uniq(issue_ids)) == 60
  end

  test "missing historical conversation binding enters audited manual review" do
    candidate = issued_ticket_candidate!()
    # A matching phone does not authorize discovery of the commercial Conversation.
    insert_conversation!()

    assert {:ok, :manual_review} =
             TicketDeliveryCoordinator.coordinate(candidate.sales_order_id)

    assert order_snapshot(candidate.sales_order_id).manual_review_reason ==
             "ticket_delivery_conversation_binding_missing"

    assert intents_for_order(candidate.sales_order_id) == []
    refute_enqueued(worker: SendWhatsAppTicketLinkWorker)
  end

  test "incomplete issuance set enters manual review without queueing partial delivery" do
    candidate = issued_ticket_candidate!()
    conversation_id = insert_conversation!()
    bind_order_to_conversation!(candidate.sales_order_id, conversation_id)

    Repo.update_all(
      from(line in "sales_order_lines", where: line.sales_order_id == ^candidate.sales_order_id),
      set: [quantity: 2, total_amount_cents: 200]
    )

    assert {:ok, :manual_review} =
             TicketDeliveryCoordinator.coordinate(candidate.sales_order_id)

    assert order_snapshot(candidate.sales_order_id).manual_review_reason ==
             "ticket_delivery_issue_set_incomplete"

    assert intents_for_order(candidate.sales_order_id) == []
    refute_enqueued(worker: SendWhatsAppTicketLinkWorker)
  end

  test "revoked issue enters manual review before creating delivery work" do
    candidate = issued_ticket_candidate!()
    conversation_id = insert_conversation!()
    bind_order_to_conversation!(candidate.sales_order_id, conversation_id)

    Repo.update_all(
      from(issue in "sales_ticket_issues", where: issue.id == ^candidate.ticket_issue_id),
      set: [status: "revoked", revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    assert {:ok, :manual_review} =
             TicketDeliveryCoordinator.coordinate(candidate.sales_order_id)

    assert order_snapshot(candidate.sales_order_id).manual_review_reason ==
             "ticket_delivery_issue_set_unsafe"

    assert intents_for_order(candidate.sales_order_id) == []
    refute_enqueued(worker: SendWhatsAppTicketLinkWorker)
  end

  defp intents_for_order(order_id) do
    Repo.all(
      from(intent in "sales_ticket_delivery_intents",
        where: intent.sales_order_id == ^order_id,
        order_by: intent.ticket_issue_id,
        select: %{id: intent.id, purpose: intent.purpose, status: intent.status}
      )
    )
  end

  defp order_snapshot(order_id) do
    Repo.one!(
      from(order in "sales_orders",
        where: order.id == ^order_id,
        select: map(order, [:status, :manual_review_reason])
      )
    )
  end

  defp bind_order_to_conversation!(order_id, conversation_id) do
    Repo.update_all(
      from(order in "sales_orders", where: order.id == ^order_id),
      set: [sales_conversation_id: conversation_id]
    )
  end

  defp add_issued_units!(candidate, quantity) do
    line_id =
      Repo.one!(
        from line in "sales_order_lines",
          where: line.sales_order_id == ^candidate.sales_order_id,
          select: line.id
      )

    Repo.update_all(
      from(line in "sales_order_lines", where: line.id == ^line_id),
      set: [quantity: quantity, total_amount_cents: quantity * 100]
    )

    for sequence <- 2..quantity do
      attendee =
        Fixtures.create_attendee(candidate.event, %{
          ticket_code: "COORD-#{candidate.sales_order_id}-#{sequence}",
          payment_status: "completed",
          sales_order_id: candidate.sales_order_id
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.query!(
        """
        INSERT INTO sales_ticket_issues
          (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
           qr_token_hash, delivery_token_hash, status, scanner_status, issued_at, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, 'issued', 'valid', $8, $8, $8)
        """,
        [
          candidate.sales_order_id,
          line_id,
          sequence,
          attendee.id,
          attendee.ticket_code,
          "coord-qr-#{candidate.sales_order_id}-#{sequence}",
          "coord-delivery-#{candidate.sales_order_id}-#{sequence}",
          now
        ]
      )
    end
  end

  defp insert_conversation! do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES ('+27821234567', $1, 'en', 'ticket_issued', '{}', false, now(), now())
        RETURNING id
        """,
        ["coord-#{System.unique_integer([:positive])}"]
      )

    id
  end
end
