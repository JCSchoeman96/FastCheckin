defmodule FastCheck.Messaging.WhatsApp.PaymentFlow do
  @moduledoc """
  VS-19 WhatsApp payment-link and ticket-link handoff.

  This module is an interface-layer orchestrator only. It does not verify
  payments, issue tickets, mutate scanner state, or call provider HTTP clients.
  """

  import Ash.Expr

  require Ash.Expr
  require Ash.Query

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.ActiveCommercialOrder
  alias FastCheck.Messaging.WhatsApp.FlowResult
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.PaymentStatusRenderer
  alias FastCheck.Messaging.WhatsApp.PurchaseFlowIdentity
  alias FastCheck.Messaging.WhatsApp.SessionStore
  alias FastCheck.Messaging.WhatsApp.TicketLinkRenderer
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.Payments.TransactionInitialization
  alias FastCheck.Workers.SendWhatsAppPaymentLinkWorker
  alias FastCheck.Workers.TicketDeliveryCoordinatorWorker

  @session_ttl_seconds 86_400

  @spec confirm_checkout_from_conversation(MessageCommand.t(), Conversation.t()) ::
          {:ok, FlowResult.t()} | {:error, term()}
  def confirm_checkout_from_conversation(
        %MessageCommand{} = command,
        %Conversation{} = conversation
      ) do
    case ActiveCommercialOrder.find_active_order(conversation) do
      {:ok, order} when not is_nil(order) ->
        respond_to_active_order(command, conversation, order)

      {:ok, nil} ->
        create_confirmation_checkout(command, conversation)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_confirmation_checkout(command, conversation) do
    data = state_data(conversation)

    with :ok <- ensure_buyer_email(data),
         {:ok, checkout} <- checkout_for_confirmation(command, conversation, data),
         {:ok, init_result} <-
           initialize_payment(checkout.checkout_session.id, checkout.order.event_id, command),
         :ok <-
           enqueue_payment_link(
             conversation.id,
             checkout.order.id,
             init_result.payment_attempt_id
           ),
         {:ok, conversation} <-
           mark_payment_pending(command, conversation, %{
             "sales_order_id" => checkout.order.id,
             "order_public_reference" => checkout.order.public_reference,
             "payment_attempt_id" => init_result.payment_attempt_id
           }) do
      {:ok,
       result(
         conversation,
         PaymentStatusRenderer.payment_link_queued(language(conversation)),
         command
       )}
    else
      {:error, :missing_buyer_email} -> request_email(command, conversation)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec respond_to_active_order(MessageCommand.t(), Conversation.t(), Order.t()) ::
          {:ok, FlowResult.t()} | {:error, term()}
  def respond_to_active_order(
        %MessageCommand{} = command,
        %Conversation{} = conversation,
        %Order{} = order
      ) do
    with {:ok, conversation} <- repair_order_checkpoint(conversation, order) do
      case respond_for_order(command, conversation, order) do
        {:ok, _result} = response ->
          response

        {:error, _reason} ->
          {:ok, result(conversation, status_response(order, language(conversation)), command)}
      end
    end
  end

  @spec respond_to_status_request(MessageCommand.t(), Conversation.t()) ::
          {:ok, FlowResult.t()} | {:error, term()}
  def respond_to_status_request(%MessageCommand{} = command, %Conversation{} = conversation) do
    case ActiveCommercialOrder.find_active_order(conversation) do
      {:ok, %Order{} = order} ->
        respond_to_active_order(command, conversation, order)

      {:ok, nil} ->
        case load_order_from_conversation(conversation) do
          {:ok, order} -> respond_for_order(command, conversation, order)
          {:error, _reason} -> support_result(command, conversation)
        end

      {:error, _reason} ->
        support_result(command, conversation)
    end
  end

  defp respond_for_order(command, conversation, %{status: status} = order)
       when status in ["awaiting_payment", "payment_pending"] do
    with :ok <- ensure_order_email(order),
         {:ok, session} <- load_checkout_session(order.id),
         {:ok, init_result} <- initialize_payment(session.id, order.event_id, command),
         :ok <- enqueue_payment_link(conversation.id, order.id, init_result.payment_attempt_id),
         {:ok, conversation} <-
           mark_payment_pending(command, conversation, %{
             "sales_order_id" => order.id,
             "order_public_reference" => order.public_reference,
             "payment_attempt_id" => init_result.payment_attempt_id
           }) do
      {:ok,
       result(
         conversation,
         PaymentStatusRenderer.payment_pending(language(conversation)),
         command
       )}
    else
      {:error, :missing_buyer_email} ->
        request_email(command, conversation)

      {:error, :payment_initialization_in_progress} ->
        {:ok,
         result(
           conversation,
           PaymentStatusRenderer.payment_pending(language(conversation)),
           command
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp respond_for_order(command, conversation, %{status: status})
       when status in [
              "paid_verified",
              "fulfillment_queued",
              "partially_issued",
              "issuance_retry_queued"
            ] do
    {:ok,
     result(conversation, PaymentStatusRenderer.ticket_preparing(language(conversation)), command)}
  end

  defp respond_for_order(command, conversation, %{status: "paid_unverified"}) do
    {:ok,
     result(conversation, PaymentStatusRenderer.payment_pending(language(conversation)), command)}
  end

  defp respond_for_order(command, conversation, %{status: "ticket_issued"} = order) do
    with :ok <- enqueue_ticket_delivery_coordinator(order.id) do
      {:ok, result(conversation, TicketLinkRenderer.sending_now(language(conversation)), command)}
    end
  end

  defp respond_for_order(command, conversation, %{status: status})
       when status in ["manual_review", "manual_review_held", "draft"] do
    {:ok,
     result(conversation, PaymentStatusRenderer.manual_review(language(conversation)), command)}
  end

  defp respond_for_order(command, conversation, %{status: status})
       when status in ["expired", "cancelled", "refunded", "no_fulfillment_closed"] do
    {:ok,
     result(conversation, PaymentStatusRenderer.terminal(language(conversation), status), command)}
  end

  defp respond_for_order(command, conversation, _order) do
    {:ok,
     result(conversation, PaymentStatusRenderer.payment_pending(language(conversation)), command)}
  end

  defp status_response(%{status: status}, language)
       when status in ["awaiting_payment", "payment_pending", "paid_unverified"],
       do: PaymentStatusRenderer.payment_pending(language)

  defp status_response(%{status: status}, language)
       when status in [
              "paid_verified",
              "fulfillment_queued",
              "partially_issued",
              "issuance_retry_queued"
            ],
       do: PaymentStatusRenderer.ticket_preparing(language)

  defp status_response(%{status: status}, language)
       when status in ["manual_review", "manual_review_held", "draft"],
       do: PaymentStatusRenderer.manual_review(language)

  defp status_response(%{status: status}, language)
       when status in ["expired", "cancelled", "refunded", "no_fulfillment_closed"],
       do: PaymentStatusRenderer.terminal(language, status)

  defp status_response(_order, language), do: PaymentStatusRenderer.manual_review(language)

  defp checkout_for_confirmation(command, conversation, data) do
    case Map.get(data, "sales_order_id") do
      order_id when is_integer(order_id) ->
        with {:ok, order} <- load_order(order_id),
             true <- order.sales_conversation_id == conversation.id,
             {:ok, session} <- load_checkout_session(order.id) do
          {:ok, %{order: order, checkout_session: session}}
        else
          false -> {:error, :conversation_order_mismatch}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        start_checkout(command, conversation, data)
    end
  end

  defp start_checkout(command, conversation, data) do
    with {:ok, idempotency_key} <- checkout_idempotency_key(conversation, data) do
      input = %{
        event_id: Map.fetch!(data, "selected_event_id"),
        ticket_offer_id: Map.fetch!(data, "selected_offer_id"),
        quantity: Map.fetch!(data, "quantity"),
        buyer_name: Map.get(data, "buyer_name"),
        buyer_phone: conversation.phone_e164,
        buyer_email: Map.get(data, "buyer_email"),
        sales_conversation_id: conversation.id,
        source_channel: "whatsapp",
        idempotency_key: idempotency_key,
        correlation_id: command.correlation_id,
        event_name: Map.fetch!(data, "selected_event_label"),
        expected_offer_lock_version: Map.get(data, "selected_offer_lock_version")
      }

      actor = customer_actor(input.event_id)
      Checkout.start_checkout(input, actor)
    end
  end

  defp checkout_idempotency_key(conversation, data) do
    case Map.get(data, "purchase_flow_id") do
      nil ->
        {:ok, PurchaseFlowIdentity.legacy_checkout_idempotency_key(conversation.id)}

      purchase_flow_id ->
        PurchaseFlowIdentity.checkout_idempotency_key(conversation.id, purchase_flow_id)
    end
  end

  defp initialize_payment(session_id, event_id, command) do
    TransactionInitialization.initialize_for_checkout_session(
      session_id,
      customer_actor(event_id),
      correlation_id: command.correlation_id,
      source_channel: "whatsapp"
    )
  end

  defp enqueue_payment_link(conversation_id, order_id, payment_attempt_id) do
    SendWhatsAppPaymentLinkWorker.new(%{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "payment_attempt_id" => payment_attempt_id
    })
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enqueue_ticket_delivery_coordinator(order_id) do
    TicketDeliveryCoordinatorWorker.new(%{"sales_order_id" => order_id})
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_payment_pending(command, conversation, extra_data) do
    data = Map.merge(state_data(conversation), extra_data)

    if conversation.state in [
         "confirming_order",
         "main_menu",
         "awaiting_payment",
         "payment_pending"
       ] do
      transition(command, conversation, :mark_conversation_payment_pending, %{state_data: data})
    else
      store_order_checkpoint(conversation, data)
    end
  end

  defp request_email(command, conversation) do
    result =
      if conversation.state in [
           "confirming_order",
           "main_menu",
           "awaiting_payment",
           "payment_pending"
         ] do
        transition(command, conversation, :request_payment_email, %{
          state_data: state_data(conversation)
        })
      else
        {:ok, conversation}
      end

    with {:ok, conversation} <- result do
      {:ok,
       result(conversation, PaymentStatusRenderer.missing_email(language(conversation)), command)}
    end
  end

  defp transition(command, conversation, action, attrs) do
    attrs =
      attrs
      |> Map.put(:last_inbound_message_id, command.provider_message_id)
      |> Map.put(:last_message_at, command.received_at)
      |> Map.put(:expires_at, DateTime.add(command.received_at, @session_ttl_seconds, :second))
      |> Map.put(:correlation_id, command.correlation_id)
      |> Map.put(:idempotency_key, command.provider_message_id)
      |> Map.put(:transition_metadata, %{source_channel: "whatsapp"})

    actor = %{actor_type: :system, actor_id: "whatsapp_payment_flow"}

    conversation
    |> Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update(authorize?: false)
  end

  defp result(conversation, body, command) do
    flow_fields = flow_fields(conversation)
    _ = SessionStore.put_flow_session(command, conversation, flow_fields, @session_ttl_seconds)

    %FlowResult{
      conversation: conversation,
      response_body: body,
      session_fields: flow_fields,
      send_reply?: true
    }
  end

  defp flow_fields(conversation) do
    data = state_data(conversation)

    %{
      sales_order_id: Map.get(data, "sales_order_id"),
      order_public_reference: Map.get(data, "order_public_reference"),
      purchase_flow_id: Map.get(data, "purchase_flow_id"),
      version: Map.get(data, "version", 0)
    }
  end

  defp load_order_from_conversation(conversation) do
    case Map.get(state_data(conversation), "sales_order_id") do
      id when is_integer(id) ->
        with {:ok, order} <- load_order(id),
             true <- order.sales_conversation_id == conversation.id do
          {:ok, order}
        else
          false -> {:error, :conversation_order_mismatch}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :order_not_found}
    end
  end

  defp repair_order_checkpoint(conversation, order) do
    data = state_data(conversation)
    order_id = order.id

    case Map.get(data, "sales_order_id") do
      nil ->
        save_order_checkpoint(conversation, data, order)

      ^order_id ->
        save_order_checkpoint(conversation, data, order)

      _other_order_id ->
        {:error, :conversation_order_mismatch}
    end
  end

  defp save_order_checkpoint(conversation, data, order) do
    repaired_data =
      data
      |> Map.put("sales_order_id", order.id)
      |> Map.put("order_public_reference", order.public_reference)

    if repaired_data == data do
      {:ok, conversation}
    else
      store_order_checkpoint(conversation, repaired_data)
    end
  end

  defp support_result(command, conversation) do
    {:ok,
     result(conversation, PaymentStatusRenderer.manual_review(language(conversation)), command)}
  end

  defp store_order_checkpoint(conversation, state_data) do
    conversation
    |> Changeset.for_update(
      :update_inbound_checkpoint,
      %{state_data: state_data},
      actor: %{actor_type: :system, actor_id: "whatsapp_payment_flow"}
    )
    |> Ash.update(authorize?: false)
  end

  defp load_order(order_id) do
    Order
    |> Query.for_read(:get_by_id, %{id: order_id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :order_not_found}
      {:ok, order} -> {:ok, order}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_checkout_session(order_id) do
    CheckoutSession
    |> Query.filter(expr(sales_order_id == ^order_id))
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :checkout_session_not_found}
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_buyer_email(data) do
    if present?(Map.get(data, "buyer_email")), do: :ok, else: {:error, :missing_buyer_email}
  end

  defp ensure_order_email(order) do
    if present?(order.buyer_email), do: :ok, else: {:error, :missing_buyer_email}
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp state_data(%{state_data: data}) when is_map(data), do: data
  defp state_data(_), do: %{}

  defp language(%{preferred_language: language}), do: language

  defp customer_actor(event_id) do
    %{actor_type: :customer_session, actor_id: "whatsapp", allowed_event_ids: [event_id]}
  end
end
