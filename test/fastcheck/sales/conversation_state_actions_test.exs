defmodule FastCheck.Sales.ConversationStateActionsTest do
  use FastCheck.DataCase, async: false

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.StateTransition

  test "named conversation action updates state and records sanitized transition" do
    conversation = insert_conversation!("new")
    actor = %{actor_type: :system, actor_id: "vs-18-test"}

    assert {:ok, updated} =
             conversation
             |> Changeset.for_update(
               :start_language_selection,
               %{
                 last_inbound_message_id: "wamid.action-1",
                 last_message_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 state_data: %{"buyer_name" => "Sensitive Buyer"},
                 correlation_id: "corr-action",
                 idempotency_key: "idem-secret",
                 transition_metadata: %{"buyer_name" => "Sensitive Buyer"}
               },
               actor: actor
             )
             |> Ash.update(authorize?: false)

    assert updated.state == "selecting_language"
    assert updated.state_data["buyer_name"] == "Sensitive Buyer"

    assert {:ok, [transition]} =
             StateTransition
             |> Query.for_read(:list_for_entity, %{
               entity_type: "conversation",
               entity_id: to_string(conversation.id)
             })
             |> Ash.read(authorize?: false)

    assert transition.from_state == "new"
    assert transition.to_state == "selecting_language"
    assert transition.correlation_id == "corr-action"
    assert transition.source == "whatsapp.conversation.start_language_selection"
    refute Map.has_key?(transition.metadata, "buyer_name")
    refute inspect(transition.metadata) =~ "Sensitive Buyer"
  end

  test "resend collection actions persist expected states" do
    conversation = insert_conversation!("main_menu")
    actor = %{actor_type: :system, actor_id: "vs-24d-c-test"}

    assert {:ok, name_state} =
             conversation
             |> Changeset.for_update(
               :choose_resend_ticket,
               %{
                 last_inbound_message_id: "wamid.resend-action-1",
                 last_message_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 state_data: %{},
                 correlation_id: "corr-resend-action-1",
                 idempotency_key: "idem-resend-action-1",
                 transition_metadata: %{}
               },
               actor: actor
             )
             |> Ash.update(authorize?: false)

    assert name_state.state == "collecting_resend_name"

    assert {:ok, email_state} =
             name_state
             |> Changeset.for_update(
               :submit_resend_name,
               %{
                 last_inbound_message_id: "wamid.resend-action-2",
                 last_message_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 state_data: %{"resend_name" => "jamie smith"},
                 correlation_id: "corr-resend-action-2",
                 idempotency_key: "idem-resend-action-2",
                 transition_metadata: %{}
               },
               actor: actor
             )
             |> Ash.update(authorize?: false)

    assert email_state.state == "collecting_resend_email"

    assert {:ok, otp_state} =
             email_state
             |> Changeset.for_update(
               :submit_resend_email,
               %{
                 last_inbound_message_id: "wamid.resend-action-3",
                 last_message_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 state_data: %{
                   "resend_name" => "jamie smith",
                   "resend_email" => "jamie@example.com"
                 },
                 correlation_id: "corr-resend-action-3",
                 idempotency_key: "idem-resend-action-3",
                 transition_metadata: %{}
               },
               actor: actor
             )
             |> Ash.update(authorize?: false)

    assert otp_state.state == "collecting_resend_otp"
  end

  defp insert_conversation!(state) do
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

    Conversation
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end
end
