defmodule FastCheck.Messaging.WhatsApp.ResendDeliveryFlow do
  @moduledoc """
  Queues verified WhatsApp ticket resend delivery through the existing ticket-link worker.
  """

  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.TicketResendChallenge
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker

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
         :ok <- ensure_deliverable_challenge(challenge, conversation),
         :ok <- enqueue_worker(challenge, conversation, oban_insert_fun) do
      {:ok, :queued, safe_updates(command)}
    end
  end

  defp challenge_public_id(%Conversation{state_data: data}) when is_map(data) do
    case Map.get(data, "resend_challenge_public_id") do
      public_id when is_binary(public_id) ->
        public_id
        |> String.trim()
        |> case do
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

  defp ensure_deliverable_challenge(
         %TicketResendChallenge{} = challenge,
         %Conversation{} = conversation
       ) do
    cond do
      challenge.status != "verified" ->
        {:error, :not_deliverable}

      challenge.conversation_id != conversation.id ->
        {:error, :not_deliverable}

      not is_integer(challenge.sales_order_id) ->
        {:error, :not_deliverable}

      not is_integer(challenge.ticket_issue_id) ->
        {:error, :not_deliverable}

      true ->
        :ok
    end
  end

  defp enqueue_worker(
         %TicketResendChallenge{} = challenge,
         %Conversation{} = conversation,
         oban_insert_fun
       ) do
    SendWhatsAppTicketLinkWorker.new(%{
      "conversation_id" => conversation.id,
      "sales_order_id" => challenge.sales_order_id,
      "ticket_issue_id" => challenge.ticket_issue_id,
      "ticket_resend_challenge_id" => challenge.id,
      "delivery_reason" => "verified_ticket_resend"
    })
    |> oban_insert_fun.()
    |> case do
      {:ok, _job} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> handle_oban_changeset_error(changeset)
      {:error, _reason} -> {:error, :not_ready}
    end
  end

  defp handle_oban_changeset_error(%Ecto.Changeset{} = changeset) do
    if oban_unique_conflict?(changeset) do
      :ok
    else
      {:error, :not_ready}
    end
  end

  defp oban_unique_conflict?(%Ecto.Changeset{} = changeset) do
    unique_constraint_error?(changeset.errors) or unique_constraint?(changeset.constraints)
  end

  defp unique_constraint_error?(errors) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique or
        Keyword.get(opts, :constraint_type) == :unique
    end)
  end

  defp unique_constraint?(constraints) do
    Enum.any?(constraints, fn constraint ->
      Map.get(constraint, :type) == :unique
    end)
  end

  defp safe_updates(%MessageCommand{} = command) do
    %{
      "resend_delivery_requested_at" => DateTime.to_iso8601(command.received_at),
      "resend_delivery_status" => "queued",
      "resend_delivery_correlation_id" => command.correlation_id
    }
  end
end
