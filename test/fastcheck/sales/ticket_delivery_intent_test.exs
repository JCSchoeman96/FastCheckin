defmodule FastCheck.Sales.TicketDeliveryIntentTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query
  import FastCheck.TicketResendFixtures

  alias Ash.Changeset
  alias Ash.Resource.Info, as: ResourceInfo
  alias FastCheck.Repo
  alias FastCheck.Sales.DeliveryAttempt
  alias FastCheck.Sales.TicketDeliveryIntent
  alias FastCheck.Tickets.Resend.Otp

  test "intent exposes its required commercial, conversation, resend, and attempt relationships" do
    assert_relationship(:order, :belongs_to, FastCheck.Sales.Order)
    assert_relationship(:ticket_issue, :belongs_to, FastCheck.Sales.TicketIssue)
    assert_relationship(:conversation, :belongs_to, FastCheck.Sales.Conversation)

    assert_relationship(
      :ticket_resend_challenge,
      :belongs_to,
      FastCheck.Sales.TicketResendChallenge
    )

    assert_relationship(:delivery_attempts, :has_many, DeliveryAttempt)
  end

  test "initial delivery is one logical intent above its transport attempts" do
    candidate = issued_ticket_candidate!()
    conversation_id = insert_conversation!()

    assert {:ok, intent} =
             TicketDeliveryIntent
             |> Changeset.for_create(
               :create_queued,
               %{
                 sales_order_id: candidate.sales_order_id,
                 ticket_issue_id: candidate.ticket_issue_id,
                 conversation_id: conversation_id,
                 purpose: "initial_ticket_delivery"
               },
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    assert intent.status == "queued"
    assert intent.purpose == "initial_ticket_delivery"
    assert intent.sales_order_id == candidate.sales_order_id
    assert intent.ticket_issue_id == candidate.ticket_issue_id
    assert intent.conversation_id == conversation_id
    assert is_nil(intent.ticket_resend_challenge_id)

    assert {:ok, accepted} =
             intent
             |> Changeset.for_update(:mark_provider_accepted, %{}, actor: system_actor())
             |> Ash.update(authorize?: false)

    assert accepted.status == "provider_accepted"
  end

  test "database uniqueness preserves one initial intent per TicketIssue" do
    candidate = issued_ticket_candidate!()
    conversation_id = insert_conversation!()

    attrs = %{
      sales_order_id: candidate.sales_order_id,
      ticket_issue_id: candidate.ticket_issue_id,
      conversation_id: conversation_id,
      purpose: "initial_ticket_delivery"
    }

    assert {:ok, _intent} = create_intent(attrs)
    assert {:error, _duplicate} = create_intent(attrs)

    assert Repo.one!(
             from(i in "sales_ticket_delivery_intents",
               where: i.ticket_issue_id == ^candidate.ticket_issue_id,
               select: count(i.id)
             )
           ) == 1
  end

  test "database uniqueness preserves one verified resend intent per challenge" do
    conversation_id = insert_conversation!()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    challenge_attrs = challenge_attrs!(conversation_id: conversation_id)

    {:ok, challenge, otp} = Otp.issue(challenge_attrs, now, return_otp?: true)

    {:ok, verified_challenge} =
      Otp.verify(challenge.public_id, otp, DateTime.add(now, 1, :second))

    attrs = %{
      sales_order_id: verified_challenge.sales_order_id,
      ticket_issue_id: verified_challenge.ticket_issue_id,
      conversation_id: conversation_id,
      ticket_resend_challenge_id: verified_challenge.id,
      purpose: "verified_ticket_resend"
    }

    assert {:ok, intent} = create_intent(attrs)
    assert {:error, _duplicate} = create_intent(attrs)

    assert Repo.one!(
             from(i in "sales_ticket_delivery_intents",
               where: i.ticket_resend_challenge_id == ^verified_challenge.id,
               select: count(i.id)
             )
           ) == 1

    assert intent.ticket_resend_challenge_id == verified_challenge.id
  end

  test "database uniqueness scopes transport attempt numbers to one intent" do
    candidate = issued_ticket_candidate!()
    conversation_id = insert_conversation!()
    intent = create_initial_intent!(candidate, conversation_id)

    attrs = %{
      sales_order_id: candidate.sales_order_id,
      ticket_issue_id: candidate.ticket_issue_id,
      ticket_delivery_intent_id: intent.id,
      channel: "whatsapp",
      provider: "meta",
      recipient: "+27***4567",
      delivery_reason: "initial_ticket_delivery",
      attempt_number: 1,
      correlation_id: "intent-attempt-#{System.unique_integer([:positive])}"
    }

    assert {:ok, _attempt} = create_delivery_attempt(attrs)
    assert {:error, _duplicate} = create_delivery_attempt(attrs)
  end

  test "query indexes cover order, conversation, issue, and attempt lookups" do
    indexes =
      Repo.query!(
        """
        SELECT indexname
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename IN ('sales_ticket_delivery_intents', 'sales_delivery_attempts')
        """,
        []
      ).rows
      |> List.flatten()
      |> MapSet.new()

    for index <- [
          "sales_ticket_delivery_intents_sales_order_id_status_index",
          "sales_ticket_delivery_intents_conversation_id_status_index",
          "sales_ticket_delivery_intents_ticket_issue_id_index",
          "sales_delivery_attempts_intent_inserted_at_idx"
        ] do
      assert MapSet.member?(indexes, index), "#{index} must exist"
    end
  end

  defp create_intent(attrs) do
    TicketDeliveryIntent
    |> Changeset.for_create(:create_queued, attrs, actor: system_actor())
    |> Ash.create(authorize?: false)
  end

  defp create_initial_intent!(candidate, conversation_id) do
    assert {:ok, intent} =
             TicketDeliveryIntent
             |> Changeset.for_create(
               :create_queued,
               %{
                 sales_order_id: candidate.sales_order_id,
                 ticket_issue_id: candidate.ticket_issue_id,
                 conversation_id: conversation_id,
                 purpose: "initial_ticket_delivery"
               },
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    intent
  end

  defp create_delivery_attempt(attrs) do
    DeliveryAttempt
    |> Changeset.for_create(:create_queued, attrs, actor: system_actor())
    |> Ash.create(authorize?: false)
  end

  defp assert_relationship(name, type, destination) do
    assert relationship = ResourceInfo.relationship(TicketDeliveryIntent, name)
    assert relationship.type == type
    assert relationship.destination == destination
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
        ["intent-#{System.unique_integer([:positive])}"]
      )

    id
  end

  defp system_actor, do: %{actor_type: :system, actor_id: "ticket-delivery-intent-test"}
end
