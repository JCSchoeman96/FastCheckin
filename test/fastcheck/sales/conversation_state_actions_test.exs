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
