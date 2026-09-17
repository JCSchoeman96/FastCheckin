defmodule FastCheck.Workers.SendWhatsAppPaymentLinkWorker do
  @moduledoc """
  Sends a Paystack authorization URL through WhatsApp with outbound dedupe.
  """

  import Ecto.Query, only: [from: 2]

  use Oban.Worker,
    queue: :whatsapp_outbound,
    max_attempts: 5,
    unique: [period: 600, fields: [:args], keys: [:conversation_id, :sales_order_id]]

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.Client
  alias FastCheck.Messaging.WhatsApp.Dedupe
  alias FastCheck.Messaging.WhatsApp.DeliveryPolicy
  alias FastCheck.Messaging.WhatsApp.TemplateCatalog
  alias FastCheck.Observability.Redactor
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.DeliveryAttempt
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.PaymentAttempt

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "conversation_id" => conversation_id,
          "sales_order_id" => order_id,
          "payment_attempt_id" => payment_attempt_id
        }
      }) do
    conversation_id = normalize_id(conversation_id)
    order_id = normalize_id(order_id)
    payment_attempt_id = normalize_id(payment_attempt_id)

    with {:ok, :new} <- Dedupe.claim_send_payment_link(conversation_id, order_id),
         {:ok, conversation} <- load_conversation(conversation_id),
         {:ok, order} <- load_order(order_id),
         {:ok, attempt} <- load_payment_attempt(payment_attempt_id),
         decision <-
           DeliveryPolicy.select_payment_link_delivery(conversation,
             fetch_template: payment_link_template_fetch_fun()
           ),
         {:ok, delivery_attempt} <- create_delivery_attempt(order, conversation, decision),
         {:ok, _delivery_attempt} <-
           deliver_and_mark(
             delivery_attempt,
             conversation,
             decision,
             attempt.authorization_url,
             fn ->
               Dedupe.release_send_payment_link(conversation_id, order_id)
             end
           ) do
      :ok
    else
      {:ok, :duplicate} ->
        :ok

      {:error, %{retryable?: true}} = error ->
        error

      {:discard, _reason} = discard ->
        discard

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(_job), do: {:discard, :invalid_args}

  defp payment_body("en", url) do
    "Pay securely with Paystack: #{url}\n\nWe will prepare your ticket once payment is confirmed."
  end

  defp payment_body(_language, url) do
    "Betaal veilig met Paystack: #{url}\n\nOns sal jou kaartjie voorberei sodra betaling bevestig is."
  end

  defp deliver_and_mark(
         delivery_attempt,
         conversation,
         %{mode: :session_message},
         url,
         release_dedupe
       ) do
    body = payment_body(conversation.preferred_language, url)

    Client.send_text(conversation.phone_e164, body,
      correlation_id: delivery_attempt.correlation_id
    )
    |> mark_provider_result(delivery_attempt, release_dedupe)
  end

  defp deliver_and_mark(
         delivery_attempt,
         conversation,
         %{mode: :template_message, template_key: template_key, template: template},
         url,
         release_dedupe
       ) do
    Client.send_template(
      conversation.phone_e164,
      template_key,
      template.language_code,
      payment_link_template_components(url),
      correlation_id: delivery_attempt.correlation_id
    )
    |> mark_provider_result(delivery_attempt, release_dedupe)
  end

  defp deliver_and_mark(
         delivery_attempt,
         _conversation,
         %{mode: :fallback_required} = decision,
         _url,
         _release_dedupe
       ) do
    with {:ok, _delivery_attempt} <-
           mark_fallback_required(
             delivery_attempt,
             decision.failure_reason,
             decision.fallback_channel
           ) do
      {:discard, :fallback_required}
    end
  end

  defp mark_provider_result(result, delivery_attempt, release_dedupe) do
    case result do
      {:ok, response} ->
        mark_sent(delivery_attempt, response.provider_message_id)

      {:error, reason} = error ->
        mark_provider_failure(delivery_attempt, reason, release_dedupe, error)
    end
  end

  defp mark_provider_failure(
         delivery_attempt,
         %{retryable?: true} = reason,
         release_dedupe,
         error
       ) do
    _ = mark_failed(delivery_attempt, reason)
    release_dedupe.()
    error
  end

  defp mark_provider_failure(
         delivery_attempt,
         %{status: status} = reason,
         _release_dedupe,
         _error
       )
       when status in [:auth_error, :validation_error] do
    _ = mark_manual_review(delivery_attempt, reason)
    {:discard, :manual_review}
  end

  defp mark_provider_failure(delivery_attempt, reason, _release_dedupe, error) do
    _ = mark_failed(delivery_attempt, reason)
    error
  end

  defp create_delivery_attempt(order, conversation, decision) do
    attrs = %{
      sales_order_id: order.id,
      ticket_issue_id: nil,
      channel: "whatsapp",
      provider: "meta",
      recipient: Redactor.redact_phone(conversation.phone_e164),
      template_name: template_name(decision),
      within_whatsapp_window: decision.within_whatsapp_window,
      attempt_number: next_attempt_number(order.id, nil),
      correlation_id: "whatsapp-payment-link-#{order.id}"
    }

    DeliveryAttempt
    |> Changeset.for_create(:create_queued, attrs, actor: system_actor())
    |> Ash.create(authorize?: false)
  end

  defp mark_sent(delivery_attempt, provider_message_id) do
    delivery_attempt
    |> Changeset.for_update(
      :mark_sent,
      %{
        provider_message_id: provider_message_id,
        sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      actor: system_actor()
    )
    |> Ash.update(authorize?: false)
  end

  defp mark_failed(delivery_attempt, reason) do
    delivery_attempt
    |> Changeset.for_update(
      :mark_failed,
      %{
        provider_error_code: provider_error_code(reason),
        provider_error_message: "whatsapp send failed",
        failure_reason: failure_reason(reason)
      },
      actor: system_actor()
    )
    |> Ash.update(authorize?: false)
  end

  defp mark_fallback_required(delivery_attempt, failure_reason, fallback_channel) do
    delivery_attempt
    |> Changeset.for_update(
      :mark_fallback_required,
      %{
        provider_error_code: "whatsapp_delivery_fallback_required",
        provider_error_message: "whatsapp delivery fallback required",
        failure_reason: failure_reason,
        fallback_channel: fallback_channel
      },
      actor: system_actor()
    )
    |> Ash.update(authorize?: false)
  end

  defp mark_manual_review(delivery_attempt, reason) do
    delivery_attempt
    |> Changeset.for_update(
      :mark_manual_review,
      %{
        provider_error_code: provider_error_code(reason),
        provider_error_message: "whatsapp send failed",
        failure_reason: failure_reason(reason),
        fallback_channel: "manual_review"
      },
      actor: system_actor()
    )
    |> Ash.update(authorize?: false)
  end

  defp provider_error_code({:error, reason}), do: provider_error_code(reason)
  defp provider_error_code(%{provider_error_code: code}) when is_binary(code), do: code
  defp provider_error_code(%{status: status}) when is_atom(status), do: Atom.to_string(status)
  defp provider_error_code(_reason), do: "whatsapp_send_failed"

  defp failure_reason({:error, reason}), do: failure_reason(reason)
  defp failure_reason(%{status: status}) when is_atom(status), do: Atom.to_string(status)
  defp failure_reason(_reason), do: "whatsapp_send_failed"

  defp next_attempt_number(order_id, nil) do
    Repo.one!(
      from d in "sales_delivery_attempts",
        where: d.sales_order_id == ^order_id and is_nil(d.ticket_issue_id),
        select: count(d.id)
    ) + 1
  end

  defp next_attempt_number(order_id, ticket_issue_id) do
    Repo.one!(
      from d in "sales_delivery_attempts",
        where: d.sales_order_id == ^order_id and d.ticket_issue_id == ^ticket_issue_id,
        select: count(d.id)
    ) + 1
  end

  defp load_conversation(id) do
    Conversation
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :conversation_not_found}
      {:ok, conversation} -> {:ok, conversation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_order(id) do
    Order
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :order_not_found}
      {:ok, order} -> {:ok, order}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_payment_attempt(id) do
    PaymentAttempt
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:error, :payment_attempt_not_found}

      {:ok, %{status: "initialized", authorization_url: url} = attempt}
      when is_binary(url) and url != "" ->
        {:ok, attempt}

      {:ok, _attempt} ->
        {:error, :payment_attempt_not_deliverable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp payment_link_template_fetch_fun do
    Application.get_env(
      :fastcheck,
      :whatsapp_payment_link_template_fetch_fun,
      &TemplateCatalog.fetch/1
    )
  end

  defp template_name(%{template: %{name: name}}), do: name
  defp template_name(_decision), do: nil

  defp payment_link_template_components(url) do
    [
      %{
        "type" => "body",
        "parameters" => [
          %{"type" => "text", "text" => url}
        ]
      }
    ]
  end

  defp system_actor, do: %{actor_type: :system, actor_id: "send_whatsapp_payment_link_worker"}
end
