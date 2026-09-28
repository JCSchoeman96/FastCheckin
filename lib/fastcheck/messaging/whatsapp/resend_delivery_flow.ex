defmodule FastCheck.Messaging.WhatsApp.ResendDeliveryFlow do
  @moduledoc """
  Creates a durable verified-resend intent and queues its ticket-link worker.
  """

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.TicketDeliveryIntent
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Sales.TicketResendChallenge
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker

  @system_actor %{actor_type: :system, actor_id: "whatsapp_resend_delivery_flow"}

  @spec enqueue_verified_ticket_link(MessageCommand.t(), Conversation.t(), keyword()) ::
          {:ok, :queued, map()} | {:error, :not_ready | :not_deliverable}
  def enqueue_verified_ticket_link(
        %MessageCommand{} = command,
        %Conversation{} = conversation,
        opts \\ []
      ) do
    oban_insert_fun = Keyword.get(opts, :oban_insert_fun, &Oban.insert/1)

    with {:ok, public_id} <- challenge_public_id(conversation),
         {:ok, challenge} <- load_challenge(public_id),
         {:ok, _intent} <- enqueue_intent_and_worker(challenge, conversation.id, oban_insert_fun) do
      {:ok, :queued, safe_updates(command)}
    end
  end

  defp challenge_public_id(%Conversation{state_data: data}) when is_map(data) do
    case Map.get(data, "resend_challenge_public_id") do
      public_id when is_binary(public_id) ->
        case String.trim(public_id) do
          "" -> {:error, :not_ready}
          value -> {:ok, value}
        end

      _other ->
        {:error, :not_ready}
    end
  end

  defp challenge_public_id(_conversation), do: {:error, :not_ready}

  defp load_challenge(public_id) do
    TicketResendChallenge
    |> Query.for_read(:get_by_public_id, %{public_id: public_id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_ready}
      {:ok, %TicketResendChallenge{} = challenge} -> {:ok, challenge}
      {:error, _reason} -> {:error, :not_ready}
    end
  end

  defp enqueue_intent_and_worker(challenge, conversation_id, oban_insert_fun) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [challenge.id])

      with {:ok, challenge} <- load_challenge_by_id(challenge.id),
           :ok <- validate_challenge(challenge, conversation_id),
           {:ok, intent} <- get_or_create_intent(challenge, conversation_id),
           :ok <- ensure_automatically_queuable(intent),
           :ok <- insert_worker(intent.id, oban_insert_fun) do
        intent
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, intent} -> {:ok, intent}
      {:error, reason} when reason in [:not_deliverable] -> {:error, :not_deliverable}
      {:error, _reason} -> {:error, :not_ready}
    end
  end

  defp load_challenge_by_id(id) do
    TicketResendChallenge
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %TicketResendChallenge{} = challenge} -> {:ok, challenge}
      _other -> {:error, :not_deliverable}
    end
  end

  defp validate_challenge(%TicketResendChallenge{} = challenge, conversation_id) do
    with :ok <- ensure_deliverable_challenge(challenge, conversation_id),
         {:ok, %Conversation{} = conversation} <- load_conversation(conversation_id),
         {:ok, %Order{} = order} <- load_order(challenge.sales_order_id),
         {:ok, %TicketIssue{} = issue} <- load_ticket_issue(challenge.ticket_issue_id),
         true <-
           challenge.conversation_id == conversation.id and
             order.status == "ticket_issued" and
             issue.sales_order_id == order.id and issue.status == "issued" and
             is_nil(issue.revoked_at) do
      :ok
    else
      _other -> {:error, :not_deliverable}
    end
  end

  defp ensure_deliverable_challenge(%TicketResendChallenge{} = challenge, conversation_id) do
    cond do
      challenge.status != "verified" ->
        {:error, :not_deliverable}

      not is_nil(challenge.consumed_at) ->
        {:error, :not_deliverable}

      challenge.conversation_id != conversation_id ->
        {:error, :not_deliverable}

      not (is_integer(challenge.sales_order_id) and challenge.sales_order_id > 0) ->
        {:error, :not_deliverable}

      not (is_integer(challenge.ticket_issue_id) and challenge.ticket_issue_id > 0) ->
        {:error, :not_deliverable}

      true ->
        :ok
    end
  end

  defp get_or_create_intent(challenge, conversation_id) do
    case TicketDeliveryIntent
         |> Query.for_read(:get_for_resend_challenge, %{
           ticket_resend_challenge_id: challenge.id
         })
         |> Ash.read_one(authorize?: false) do
      {:ok, %TicketDeliveryIntent{} = intent} ->
        if intent.purpose == "verified_ticket_resend" and
             intent.sales_order_id == challenge.sales_order_id and
             intent.ticket_issue_id == challenge.ticket_issue_id and
             intent.conversation_id == conversation_id do
          {:ok, intent}
        else
          {:error, :not_deliverable}
        end

      {:ok, nil} ->
        TicketDeliveryIntent
        |> Changeset.for_create(
          :create_queued,
          %{
            sales_order_id: challenge.sales_order_id,
            ticket_issue_id: challenge.ticket_issue_id,
            conversation_id: conversation_id,
            ticket_resend_challenge_id: challenge.id,
            purpose: "verified_ticket_resend"
          },
          actor: @system_actor
        )
        |> Ash.create(authorize?: false)
        |> case do
          {:ok, intent} -> {:ok, intent}
          {:error, _reason} -> {:error, :not_ready}
        end

      {:error, _reason} ->
        {:error, :not_ready}
    end
  end

  defp ensure_automatically_queuable(%TicketDeliveryIntent{status: status})
       when status in ["queued", "provider_accepted"],
       do: :ok

  defp ensure_automatically_queuable(_intent), do: {:error, :not_deliverable}

  defp insert_worker(intent_id, oban_insert_fun) do
    SendWhatsAppTicketLinkWorker.new(%{"ticket_delivery_intent_id" => intent_id})
    |> oban_insert_fun.()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_conflict?(changeset), do: :ok, else: {:error, :not_ready}

      {:error, _reason} ->
        {:error, :not_ready}
    end
  end

  defp unique_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique or
        Keyword.get(opts, :constraint_type) == :unique
    end)
  end

  defp load_conversation(id), do: read_one(Conversation, :get_by_id, %{id: id})
  defp load_order(id), do: read_one(Order, :get_by_id, %{id: id})
  defp load_ticket_issue(id), do: read_one(TicketIssue, :get_by_id, %{id: id})

  defp read_one(resource, action, args) do
    resource
    |> Query.for_read(action, args)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_updates(%MessageCommand{} = command) do
    %{
      "resend_delivery_requested_at" => DateTime.to_iso8601(command.received_at),
      "resend_delivery_status" => "queued",
      "resend_delivery_correlation_id" => command.correlation_id
    }
  end
end
