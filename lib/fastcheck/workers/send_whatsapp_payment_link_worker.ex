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
         {:ok, delivery_attempt} <- create_delivery_attempt(order, nil, conversation),
         body <- payment_body(conversation.preferred_language, attempt.authorization_url),
         :ok <-
           send_and_mark(delivery_attempt, conversation.phone_e164, body, fn ->
             Dedupe.release_send_payment_link(conversation_id, order_id)
           end) do
      :ok
    else
      {:ok, :duplicate} ->
        :ok

      {:discard, _reason} = discard ->
        discard

      {:error, %{retryable?: true}} = error ->
        error

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

  defp send_and_mark(delivery_attempt, phone_e164, body, release_dedupe) do
    case Client.send_text(phone_e164, body, correlation_id: delivery_attempt.correlation_id) do
      {:ok, response} ->
        case mark_provider_accepted(delivery_attempt, response.provider_message_id) do
          {:ok, _delivery_attempt} ->
            :ok

          {:error, _reason} ->
            _ = mark_manual_review(delivery_attempt, :provider_acceptance_persistence_failed)
            {:discard, :provider_acceptance_persistence_failed}
        end

      {:error, %{ambiguous?: true} = reason} ->
        _ = mark_manual_review(delivery_attempt, reason)
        {:discard, :ambiguous_transport}

      {:error, reason} = error ->
        _ = mark_failed(delivery_attempt, reason)
        release_if_retryable(reason, release_dedupe)
        error
    end
  end

  defp create_delivery_attempt(order, ticket_issue_id, conversation) do
    attrs = %{
      sales_order_id: order.id,
      ticket_issue_id: ticket_issue_id,
      channel: "whatsapp",
      provider: "meta",
      recipient: Redactor.redact_phone(conversation.phone_e164),
      attempt_number: next_attempt_number(order.id, ticket_issue_id),
      correlation_id: "whatsapp-payment-link-#{order.id}"
    }

    DeliveryAttempt
    |> Changeset.for_create(:create_queued, attrs, actor: system_actor())
    |> Ash.create(authorize?: false)
  end

  defp mark_provider_accepted(delivery_attempt, provider_message_id) do
    accepted_at = DateTime.utc_now() |> DateTime.truncate(:second)

    delivery_attempt
    |> Changeset.for_update(
      :mark_provider_accepted,
      %{
        provider_message_id: provider_message_id,
        provider_accepted_at: accepted_at,
        provider_status: "accepted",
        provider_status_at: accepted_at
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
        failure_reason: failure_reason(reason),
        failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        provider_status: "failed",
        provider_status_at: DateTime.utc_now() |> DateTime.truncate(:second)
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
        provider_error_message: "whatsapp send requires manual review",
        failure_reason: failure_reason(reason),
        fallback_channel: "manual_review"
      },
      actor: system_actor()
    )
    |> Ash.update(authorize?: false)
  end

  defp provider_error_code(%{provider_error_code: code}) when is_binary(code), do: code
  defp provider_error_code(%{status: status}) when is_atom(status), do: Atom.to_string(status)
  defp provider_error_code(_reason), do: "whatsapp_send_failed"

  defp failure_reason(%{status: status}) when is_atom(status), do: Atom.to_string(status)
  defp failure_reason(_reason), do: "whatsapp_send_failed"

  defp release_if_retryable(%{retryable?: true}, release_dedupe), do: release_dedupe.()
  defp release_if_retryable(_reason, _release_dedupe), do: :ok

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

      {:ok, %{status: "initialized", authorization_url: url} = attempt} when is_binary(url) ->
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

  defp system_actor, do: %{actor_type: :system, actor_id: "send_whatsapp_payment_link_worker"}
end
