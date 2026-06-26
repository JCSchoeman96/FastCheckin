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
  alias FastCheck.Messaging.WhatsApp.FlowResult
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.PaymentStatusRenderer
  alias FastCheck.Messaging.WhatsApp.SessionStore
  alias FastCheck.Messaging.WhatsApp.TicketLinkRenderer
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.Payments.TransactionInitialization
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Workers.SendWhatsAppPaymentLinkWorker
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker

  @session_ttl_seconds 86_400

  @spec confirm_checkout_from_conversation(MessageCommand.t(), Conversation.t()) ::
          {:ok, FlowResult.t()} | {:error, term()}
  def confirm_checkout_from_conversation(
        %MessageCommand{} = command,
        %Conversation{} = conversation
      ) do
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

  @spec respond_to_status_request(MessageCommand.t(), Conversation.t()) ::
          {:ok, FlowResult.t()} | {:error, term()}
  def respond_to_status_request(%MessageCommand{} = command, %Conversation{} = conversation) do
    case load_order_from_conversation(conversation) do
      {:ok, order} ->
        respond_for_order(command, conversation, order)

      {:error, _reason} ->
        {:ok,
         result(
           conversation,
           PaymentStatusRenderer.manual_review(language(conversation)),
           command
         )}
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
       when status in ["paid_verified", "fulfillment_queued"] do
    {:ok,
     result(conversation, PaymentStatusRenderer.ticket_preparing(language(conversation)), command)}
  end

  defp respond_for_order(command, conversation, %{status: "ticket_issued"} = order) do
    case load_deliverable_ticket_issue(order.id) do
      {:ok, ticket_issue} ->
        :ok = enqueue_ticket_link(conversation.id, order.id, ticket_issue.id)

        {:ok,
         result(conversation, TicketLinkRenderer.sending_now(language(conversation)), command)}

      {:error, :not_found} ->
        {:ok, result(conversation, TicketLinkRenderer.not_ready(language(conversation)), command)}
    end
  end

  defp respond_for_order(command, conversation, %{status: "manual_review"}) do
    {:ok,
     result(conversation, PaymentStatusRenderer.manual_review(language(conversation)), command)}
  end

  defp respond_for_order(command, conversation, %{status: status})
       when status in ["expired", "cancelled", "refunded"] do
    {:ok,
     result(conversation, PaymentStatusRenderer.terminal(language(conversation), status), command)}
  end

  defp respond_for_order(command, conversation, _order) do
    {:ok,
     result(conversation, PaymentStatusRenderer.payment_pending(language(conversation)), command)}
  end

  defp checkout_for_confirmation(command, conversation, data) do
    case Map.get(data, "sales_order_id") do
      order_id when is_integer(order_id) ->
        with {:ok, order} <- load_order(order_id),
             {:ok, session} <- load_checkout_session(order.id) do
          {:ok, %{order: order, checkout_session: session}}
        end

      _ ->
        start_checkout(command, conversation, data)
    end
  end

  defp start_checkout(command, conversation, data) do
    input = %{
      event_id: Map.fetch!(data, "selected_event_id"),
      ticket_offer_id: Map.fetch!(data, "selected_offer_id"),
      quantity: Map.fetch!(data, "quantity"),
      buyer_name: Map.get(data, "buyer_name"),
      buyer_phone: conversation.phone_e164,
      buyer_email: Map.get(data, "buyer_email"),
      source_channel: "whatsapp",
      idempotency_key: "whatsapp:conversation:#{conversation.id}:checkout",
      correlation_id: command.correlation_id,
      event_name: Map.fetch!(data, "selected_event_label")
    }

    actor = customer_actor(input.event_id)
    Checkout.start_checkout(input, actor)
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

  defp enqueue_ticket_link(conversation_id, order_id, ticket_issue_id) do
    SendWhatsAppTicketLinkWorker.new(%{
      "conversation_id" => conversation_id,
      "sales_order_id" => order_id,
      "ticket_issue_id" => ticket_issue_id
    })
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_payment_pending(command, conversation, extra_data) do
    data = Map.merge(state_data(conversation), extra_data)

    transition(command, conversation, :mark_conversation_payment_pending, %{
      state_data: data
    })
  end

  defp request_email(command, conversation) do
    with {:ok, conversation} <-
           transition(command, conversation, :request_payment_email, %{
             state_data: state_data(conversation)
           }) do
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
      version: Map.get(data, "version", 0)
    }
  end

  defp load_order_from_conversation(conversation) do
    case Map.get(state_data(conversation), "sales_order_id") do
      id when is_integer(id) -> load_order(id)
      _ -> {:error, :order_not_found}
    end
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

  defp load_deliverable_ticket_issue(order_id) do
    TicketIssue
    |> Query.for_read(:list_issued_by_order, %{sales_order_id: order_id})
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [issue | _]} -> {:ok, issue}
      {:ok, []} -> {:error, :not_found}
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
