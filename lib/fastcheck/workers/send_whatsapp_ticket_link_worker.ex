defmodule FastCheck.Workers.SendWhatsAppTicketLinkWorker do
  @moduledoc """
  Sends a secure ticket page link through WhatsApp after backend issuance exists.
  """

  import Ecto.Query, only: [from: 2]

  use Oban.Worker,
    queue: :whatsapp_outbound,
    max_attempts: 5,
    unique: [period: 600, fields: [:args], keys: [:conversation_id, :ticket_issue_id]]

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.Client
  alias FastCheck.Messaging.WhatsApp.Dedupe
  alias FastCheck.Messaging.WhatsApp.TicketLinkRenderer
  alias FastCheck.Observability.Redactor
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.DeliveryAttempt
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Sales.TicketPage
  alias FastCheck.Tickets.DeliveryToken

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "conversation_id" => conversation_id,
          "sales_order_id" => order_id,
          "ticket_issue_id" => ticket_issue_id
        }
      }) do
    conversation_id = normalize_id(conversation_id)
    order_id = normalize_id(order_id)
    ticket_issue_id = normalize_id(ticket_issue_id)

    with {:ok, :new} <- Dedupe.claim_send_ticket_link(conversation_id, ticket_issue_id),
         {:ok, conversation} <- load_conversation(conversation_id),
         {:ok, order} <- load_order(order_id),
         :ok <- ensure_order_deliverable(order),
         {:ok, ticket_issue} <- load_ticket_issue(ticket_issue_id),
         :ok <- ensure_ticket_issue_deliverable(ticket_issue),
         token <- DeliveryToken.generate(),
         {:ok, ticket_issue} <- rotate_token(ticket_issue, token),
         url <- ticket_url(token.token),
         :ok <- ensure_secure_page_valid(token.token),
         {:ok, delivery_attempt} <- create_delivery_attempt(order, ticket_issue, conversation),
         body <- TicketLinkRenderer.ticket_link(conversation.preferred_language, url),
         :ok <-
           send_and_mark(delivery_attempt, conversation.phone_e164, body, fn ->
             Dedupe.release_send_ticket_link(conversation_id, ticket_issue_id)
           end) do
      :ok
    else
      {:ok, :duplicate} ->
        :ok

      {:error, :ticket_not_deliverable} ->
        {:discard, :ticket_not_deliverable}

      {:error, %{retryable?: true}} = error ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(_job), do: {:discard, :invalid_args}

  defp ensure_order_deliverable(%{status: "ticket_issued"}), do: :ok
  defp ensure_order_deliverable(_order), do: {:error, :ticket_not_deliverable}

  defp ensure_ticket_issue_deliverable(%{status: "issued", revoked_at: nil}), do: :ok
  defp ensure_ticket_issue_deliverable(_ticket_issue), do: {:error, :ticket_not_deliverable}

  defp rotate_token(ticket_issue, token) do
    ticket_issue
    |> Changeset.for_update(
      :rotate_delivery_token_for_delivery,
      %{
        delivery_token_hash: token.hash,
        delivery_token_expires_at: token.expires_at
      },
      actor: system_actor()
    )
    |> Ash.update(
      authorize?: false,
      context: %{
        actor: system_actor(),
        correlation_id: "whatsapp-ticket-link-#{ticket_issue.id}"
      }
    )
  end

  defp ensure_secure_page_valid(token) do
    case TicketPage.resolve(token) do
      %{state: :valid} -> :ok
      _ -> {:error, :ticket_not_deliverable}
    end
  end

  defp ticket_url(token), do: FastCheckWeb.Endpoint.url() <> "/t/" <> token

  defp send_and_mark(delivery_attempt, phone_e164, body, release_dedupe) do
    case Client.send_text(phone_e164, body, correlation_id: delivery_attempt.correlation_id) do
      {:ok, response} ->
        with {:ok, _delivery_attempt} <- mark_sent(delivery_attempt, response.provider_message_id) do
          :ok
        end

      {:error, reason} = error ->
        _ = mark_failed(delivery_attempt, reason)
        release_if_retryable(reason, release_dedupe)
        error
    end
  end

  defp create_delivery_attempt(order, ticket_issue, conversation) do
    attrs = %{
      sales_order_id: order.id,
      ticket_issue_id: ticket_issue.id,
      channel: "whatsapp",
      provider: "meta",
      recipient: Redactor.redact_phone(conversation.phone_e164),
      attempt_number: next_attempt_number(order.id, ticket_issue.id),
      correlation_id: "whatsapp-ticket-link-#{ticket_issue.id}"
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

  defp provider_error_code({:error, reason}), do: provider_error_code(reason)
  defp provider_error_code(%{provider_error_code: code}) when is_binary(code), do: code
  defp provider_error_code(%{status: status}) when is_atom(status), do: Atom.to_string(status)
  defp provider_error_code(_reason), do: "whatsapp_send_failed"

  defp failure_reason({:error, reason}), do: failure_reason(reason)
  defp failure_reason(%{status: status}) when is_atom(status), do: Atom.to_string(status)
  defp failure_reason(_reason), do: "whatsapp_send_failed"

  defp release_if_retryable(%{retryable?: true}, release_dedupe), do: release_dedupe.()
  defp release_if_retryable(_reason, _release_dedupe), do: :ok

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

  defp load_ticket_issue(id) do
    TicketIssue
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :ticket_issue_not_found}
      {:ok, ticket_issue} -> {:ok, ticket_issue}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp system_actor, do: %{actor_type: :system, actor_id: "send_whatsapp_ticket_link_worker"}
end
