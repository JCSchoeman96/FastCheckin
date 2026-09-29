defmodule FastCheck.Sales.ConversationStateActionsTest do
  use FastCheck.DataCase, async: false

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.PurchaseFlowIdentity
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.StateTransition

  @conversation_states [
    "new",
    "selecting_language",
    "main_menu",
    "selecting_event",
    "selecting_ticket_type",
    "collecting_quantity",
    "collecting_buyer_name",
    "collecting_email",
    "confirming_order",
    "awaiting_payment",
    "payment_pending",
    "payment_received",
    "ticket_issued",
    "completed",
    "manual_review",
    "cancelled",
    "expired",
    "collecting_resend_name",
    "collecting_resend_email",
    "collecting_resend_otp",
    "awaiting_verified_resend_delivery",
    "verified_resend_delivery_queued"
  ]

  @transition_cases [
    {:start_language_selection, ["new"], "selecting_language"},
    {:start_default_main_menu, ["new"], "main_menu"},
    {:select_language, ["selecting_language"], "main_menu"},
    {:choose_buy_tickets, ["main_menu"], "selecting_event"},
    {:choose_resend_ticket, ["main_menu"], "collecting_resend_name"},
    {:select_event, ["selecting_event"], "selecting_ticket_type"},
    {:select_ticket_type, ["selecting_ticket_type"], "collecting_quantity"},
    {:submit_quantity, ["collecting_quantity"], "collecting_buyer_name"},
    {:submit_buyer_name, ["collecting_buyer_name"], "collecting_email"},
    {:submit_buyer_email, ["collecting_email"], "confirming_order"},
    {:submit_resend_name, ["collecting_resend_name"], "collecting_resend_email"},
    {:submit_resend_email, ["collecting_resend_email"], "collecting_resend_otp"},
    {:skip_optional_email_after_name, ["collecting_email"], "confirming_order"},
    {:confirm_order, ["confirming_order"], "awaiting_payment"},
    {:return_to_event_selection,
     ["selecting_event", "selecting_ticket_type", "collecting_quantity", "confirming_order"],
     "selecting_event"},
    {:return_to_ticket_type_selection,
     ["selecting_ticket_type", "collecting_quantity", "confirming_order"],
     "selecting_ticket_type"},
    {:return_to_quantity_collection, ["collecting_buyer_name", "confirming_order"],
     "collecting_quantity"},
    {:return_to_buyer_name_collection, ["collecting_email"], "collecting_buyer_name"},
    {:return_to_email_collection, ["confirming_order"], "collecting_email"},
    {:return_to_resend_name_collection, ["collecting_resend_email"], "collecting_resend_name"},
    {:return_to_resend_email_collection, ["collecting_resend_otp"], "collecting_resend_email"},
    {:verify_resend_otp, ["collecting_resend_otp"], "awaiting_verified_resend_delivery"},
    {:queue_verified_resend_delivery, ["awaiting_verified_resend_delivery"],
     "verified_resend_delivery_queued"},
    {:return_to_main_menu,
     [
       "selecting_event",
       "selecting_ticket_type",
       "collecting_quantity",
       "confirming_order",
       "collecting_resend_name"
     ], "main_menu"},
    {:restart_to_main_menu,
     [
       "new",
       "selecting_language",
       "main_menu",
       "selecting_event",
       "selecting_ticket_type",
       "collecting_quantity",
       "collecting_buyer_name",
       "collecting_email",
       "confirming_order",
       "awaiting_payment",
       "payment_pending",
       "payment_received",
       "ticket_issued",
       "completed",
       "manual_review",
       "cancelled",
       "expired",
       "collecting_resend_name",
       "collecting_resend_email",
       "collecting_resend_otp",
       "awaiting_verified_resend_delivery",
       "verified_resend_delivery_queued"
     ], "main_menu"},
    {:cancel_conversation,
     [
       "new",
       "selecting_language",
       "main_menu",
       "selecting_event",
       "selecting_ticket_type",
       "collecting_quantity",
       "collecting_buyer_name",
       "collecting_email",
       "confirming_order",
       "collecting_resend_name",
       "collecting_resend_email",
       "collecting_resend_otp",
       "awaiting_verified_resend_delivery",
       "verified_resend_delivery_queued"
     ], "cancelled"},
    {:handoff_conversation,
     [
       "new",
       "selecting_language",
       "main_menu",
       "selecting_event",
       "selecting_ticket_type",
       "collecting_quantity",
       "collecting_buyer_name",
       "collecting_email",
       "confirming_order",
       "awaiting_payment",
       "payment_pending",
       "payment_received",
       "ticket_issued",
       "collecting_resend_name",
       "collecting_resend_email",
       "collecting_resend_otp",
       "awaiting_verified_resend_delivery",
       "verified_resend_delivery_queued"
     ], "manual_review"},
    {:mark_conversation_payment_pending,
     ["confirming_order", "main_menu", "awaiting_payment", "payment_pending"], "payment_pending"},
    {:request_payment_email,
     ["confirming_order", "main_menu", "awaiting_payment", "payment_pending"], "collecting_email"}
  ]

  for {action, allowed_from, target_state} <- @transition_cases do
    illegal_source_state =
      Enum.find(@conversation_states, &(&1 not in allowed_from)) ||
        "outside_transition_matrix"

    test "#{action} accepts every declared source state" do
      action = unquote(action)

      for source_state <- unquote(allowed_from) do
        conversation = insert_conversation!(source_state)

        assert {:ok, updated} = update_transition(conversation, action)
        assert updated.state == unquote(target_state)

        assert_purchase_flow_identity(action, updated)
      end
    end

    test "#{action} rejects a source outside its declared state matrix" do
      conversation = %{insert_conversation!("new") | state: unquote(illegal_source_state)}
      assert {:error, _reason} = update_transition(conversation, unquote(action))
    end
  end

  test "buy and email actions reject representative legal but disallowed source states" do
    payment_pending = %{insert_conversation!("new") | state: "payment_pending"}
    collecting_quantity = %{insert_conversation!("new") | state: "collecting_quantity"}

    assert {:error, _reason} = update_transition(payment_pending, :choose_buy_tickets)
    assert {:error, _reason} = update_transition(collecting_quantity, :submit_buyer_email)
  end

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

    assert {:ok, verified_state} =
             otp_state
             |> Changeset.for_update(
               :verify_resend_otp,
               %{
                 last_inbound_message_id: "wamid.resend-action-4",
                 last_message_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 state_data: %{
                   "resend_name" => "jamie smith",
                   "resend_email" => "jamie@example.com",
                   "resend_challenge_public_id" => "challenge-public-test",
                   "resend_otp_verification_status" => "verified"
                 },
                 correlation_id: "corr-resend-action-4",
                 idempotency_key: "idem-resend-action-4",
                 transition_metadata: %{}
               },
               actor: actor
             )
             |> Ash.update(authorize?: false)

    assert verified_state.state == "awaiting_verified_resend_delivery"

    assert {:ok, queued_state} =
             verified_state
             |> Changeset.for_update(
               :queue_verified_resend_delivery,
               %{
                 last_inbound_message_id: "wamid.resend-action-5",
                 last_message_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 state_data: %{
                   "resend_otp_verification_status" => "verified",
                   "resend_otp_verified_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                   "resend_delivery_status" => "queued",
                   "resend_delivery_requested_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
                   "resend_delivery_correlation_id" => "corr-resend-action-5"
                 },
                 correlation_id: "corr-resend-action-5",
                 idempotency_key: "idem-resend-action-5",
                 transition_metadata: %{}
               },
               actor: actor
             )
             |> Ash.update(authorize?: false)

    assert queued_state.state == "verified_resend_delivery_queued"
    refute Map.has_key?(queued_state.state_data, "resend_challenge_public_id")
  end

  defp insert_conversation!(state) do
    suffix =
      System.unique_integer([:positive])
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES
          ($2, $3, 'af', $1, '{}', false, now(), now())
        RETURNING id
        """,
        [state, "+2782#{suffix}", "2782#{suffix}"]
      )

    Conversation
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp update_transition(conversation, action) do
    attrs = %{
      state_data: %{},
      last_inbound_message_id: "wamid.matrix-#{action}-#{System.unique_integer([:positive])}",
      last_message_at: DateTime.utc_now() |> DateTime.truncate(:second),
      correlation_id: "corr-matrix-#{action}",
      idempotency_key: "idem-matrix-#{action}-#{System.unique_integer([:positive])}",
      transition_metadata: %{}
    }

    attrs =
      if action in [:cancel_conversation, :handoff_conversation],
        do: Map.put(attrs, :reason, "test transition"),
        else: attrs

    conversation
    |> Changeset.for_update(action, attrs, actor: %{actor_type: :system, actor_id: "test"})
    |> Ash.update(authorize?: false)
  end

  defp assert_purchase_flow_identity(:choose_buy_tickets, conversation) do
    assert PurchaseFlowIdentity.valid?(conversation.state_data["purchase_flow_id"])
  end

  defp assert_purchase_flow_identity(:choose_resend_ticket, conversation) do
    refute Map.has_key?(conversation.state_data, "purchase_flow_id")
  end

  defp assert_purchase_flow_identity(_action, _conversation), do: :ok
end
