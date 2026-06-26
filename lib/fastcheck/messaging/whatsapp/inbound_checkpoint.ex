defmodule FastCheck.Messaging.WhatsApp.InboundCheckpoint do
  @moduledoc """
  Minimal durable Conversation checkpointing for signed inbound WhatsApp messages.
  """

  require Ash.Query
  import Ash.Expr

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.SessionStore
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation

  @spec checkpoint(MessageCommand.t(), pos_integer()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def checkpoint(%MessageCommand{} = command, ttl_seconds)
      when is_integer(ttl_seconds) and ttl_seconds > 0 do
    Repo.transaction(fn ->
      :ok = advisory_lock(command.wa_id)

      case latest_conversation(command.wa_id) do
        {:ok, nil} -> create_checkpoint(command, ttl_seconds)
        {:ok, conversation} -> update_checkpoint(conversation, command, ttl_seconds)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def checkpoint(_command, _ttl_seconds), do: {:error, :invalid_args}

  defp create_checkpoint(command, ttl_seconds) do
    attrs = attrs(command, ttl_seconds)

    Conversation
    |> Changeset.for_create(:create_inbound_checkpoint, attrs, actor: system_actor())
    |> Ash.create(authorize?: false, return_notifications?: true)
    |> unwrap_or_rollback()
  end

  defp update_checkpoint(conversation, command, ttl_seconds) do
    attrs = attrs(command, ttl_seconds)
    attrs = Map.delete(attrs, :state)

    conversation
    |> Changeset.for_update(:update_inbound_checkpoint, attrs, actor: system_actor())
    |> Ash.update(authorize?: false, return_notifications?: true)
    |> unwrap_or_rollback()
  end

  defp latest_conversation(wa_id) do
    Conversation
    |> Query.filter(expr(wa_id == ^wa_id))
    |> Query.sort(inserted_at: :desc)
    |> Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end

  defp attrs(command, ttl_seconds) do
    %{
      phone_e164: command.phone_e164,
      wa_id: command.wa_id,
      session_key: SessionStore.key_for_wa_id(command.wa_id),
      rate_limit_key: "whatsapp_webhook:#{hash(command.wa_id)}",
      preferred_language: "af",
      state: "new",
      state_data: %{},
      last_inbound_message_id: command.provider_message_id,
      last_message_at: command.received_at,
      expires_at: DateTime.add(command.received_at, ttl_seconds, :second),
      needs_human: false,
      handoff_reason: nil
    }
  end

  defp advisory_lock(wa_id) do
    lock_id =
      :crypto.hash(:sha256, wa_id)
      |> binary_part(0, 8)
      |> :binary.decode_unsigned()
      |> rem(9_223_372_036_854_775_807)

    Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_id])
    :ok
  end

  defp unwrap_or_rollback({:ok, conversation, _notifications}), do: conversation
  defp unwrap_or_rollback({:ok, conversation}), do: conversation
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp system_actor, do: %{actor_type: :system, actor_id: "whatsapp_inbound_checkpoint"}

  defp hash(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
