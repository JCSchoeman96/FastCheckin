defmodule FastCheck.Workers.WhatsAppInboundWorker do
  @moduledoc """
  VS-17 WhatsApp inbound handoff worker.

  Loads fresh Conversation state and emits safe operational telemetry only. Later
  slices own the actual WhatsApp conversation flow.
  """

  use Oban.Worker,
    queue: :whatsapp_inbound,
    max_attempts: 5,
    unique: [period: 86_400, fields: [:args], keys: [:provider_message_id]]

  require Logger

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Crypto
  alias FastCheck.Messaging.WhatsApp.Client
  alias FastCheck.Messaging.WhatsApp.ConversationStateMachine
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Observability.Correlation
  alias FastCheck.Sales.Conversation

  @unresolved_reply_statuses ["reply_pending", "reply_retryable"]

  @impl Oban.Worker
  def new(args, opts) when is_map(args) and is_list(opts) do
    args
    |> sanitize_args()
    |> Oban.Job.new(Oban.Worker.merge_opts(__opts__(), opts))
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"conversation_id" => conversation_id} = args} = job) do
    with {:ok, %Conversation{} = conversation} <- load_conversation(conversation_id) do
      metadata =
        Correlation.operational_metadata(%{
          correlation_id: Map.get(args, "correlation_id"),
          conversation_id: conversation.id,
          provider: "meta",
          channel: "whatsapp",
          status: "received",
          message_type: Map.get(args, "message_type"),
          provider_reference_redacted: provider_hash(Map.get(args, "provider_message_id"))
        })
        |> Map.new()

      :telemetry.execute(
        [:fastcheck, :sales, :whatsapp, :inbound_received],
        %{count: 1},
        metadata
      )

      Logger.info("whatsapp_inbound_worker_received", metadata)
      handle_flow(job, args, conversation)
    end
  end

  def perform(_job), do: {:error, :invalid_args}

  defp sanitize_args(args) do
    stringified = stringify_keys(args)

    stringified
    |> stringify_keys()
    |> Map.delete("text_body")
    |> Map.delete("phone_e164")
    |> Map.delete("wa_id")
    |> Map.put_new("phone_e164_redacted", redact_phone(Map.get(stringified, "phone_e164")))
    |> Map.put_new("wa_id_hash", provider_hash(Map.get(stringified, "wa_id")))
    |> Map.update("text_body_redacted_or_reference", nil, fn _ -> "[FILTERED_MESSAGE]" end)
  end

  defp handle_flow(job, args, conversation) do
    case unresolved_pending_reply(conversation) do
      {:ok, pending_reply} -> deliver_stored_reply(job, conversation, pending_reply)
      {:invalid, pending_reply} -> fail_stored_reply(conversation, pending_reply)
      :none -> process_fresh_inbound(job, args, conversation)
    end
  end

  defp process_fresh_inbound(job, args, conversation) do
    case decrypt_text_body(Map.get(args, "text_body_encrypted")) do
      {:ok, text_body} ->
        command = command_from_args(args, conversation, text_body)

        case ConversationStateMachine.handle_inbound(command, conversation) do
          {:ok, result} -> deliver_computed_reply(job, command, result)
          {:error, reason} -> {:error, reason}
        end

      :no_text ->
        :ok

      {:error, _reason} ->
        {:error, :invalid_encrypted_text_body}
    end
  end

  defp decrypt_text_body(nil), do: :no_text
  defp decrypt_text_body(""), do: :no_text
  defp decrypt_text_body(value) when is_binary(value), do: Crypto.decrypt(value)

  defp deliver_computed_reply(_job, _command, %{send_reply?: false}), do: :ok

  defp deliver_computed_reply(job, command, result) do
    deliver_reply_body(
      job,
      result.conversation,
      command.provider_message_id,
      result.response_body,
      command.correlation_id
    )
  end

  defp deliver_stored_reply(job, conversation, pending_reply) do
    case Crypto.decrypt(pending_reply["ciphertext"]) do
      {:ok, body} ->
        deliver_reply_body(
          job,
          conversation,
          pending_reply["provider_message_id"],
          body,
          Map.get(job.args, "correlation_id")
        )

      {:error, _reason} ->
        fail_stored_reply(conversation, pending_reply)
    end
  end

  defp deliver_reply_body(job, conversation, provider_message_id, body, correlation_id) do
    case Client.send_text(conversation.phone_e164, body, correlation_id: correlation_id) do
      {:ok, response} ->
        mark_reply_sent(conversation, provider_message_id, response.provider_message_id)

      {:error, response} ->
        handle_delivery_failure(job, conversation, provider_message_id, response)
    end
  end

  defp handle_delivery_failure(job, conversation, provider_message_id, response) do
    if response.retryable? do
      handle_retryable_failure(job, conversation, provider_message_id)
    else
      failure_class = permanent_failure_class(response)

      case mark_reply_failed(conversation, provider_message_id, failure_class) do
        :ok -> {:discard, :whatsapp_reply_failed}
        {:error, _reason} -> {:error, :whatsapp_reply_checkpoint_failed}
      end
    end
  end

  defp handle_retryable_failure(job, conversation, provider_message_id) do
    if final_attempt?(job) do
      case mark_reply_failed(conversation, provider_message_id, "whatsapp_reply_retry_exhausted") do
        :ok -> {:discard, :whatsapp_reply_retry_exhausted}
        {:error, _reason} -> {:error, :whatsapp_reply_checkpoint_failed}
      end
    else
      case mark_reply_retryable(conversation, provider_message_id) do
        :ok -> {:error, :whatsapp_send_retryable}
        {:error, _reason} -> {:error, :whatsapp_reply_checkpoint_failed}
      end
    end
  end

  defp mark_reply_retryable(conversation, provider_message_id) do
    update_reply(conversation, :mark_reply_retryable, %{
      provider_message_id: provider_message_id,
      attempted_at: now(),
      failure_class: "whatsapp_reply_transport_failure"
    })
  end

  defp mark_reply_sent(conversation, provider_message_id, outbound_message_id)
       when is_binary(outbound_message_id) and outbound_message_id != "" do
    update_reply(conversation, :mark_reply_sent, %{
      provider_message_id: provider_message_id,
      outbound_message_id: outbound_message_id,
      sent_at: now()
    })
  end

  defp mark_reply_sent(_conversation, _provider_message_id, _outbound_message_id),
    do: {:error, :missing_outbound_message_id}

  defp mark_reply_failed(conversation, provider_message_id, failure_class) do
    update_reply(conversation, :mark_reply_failed, %{
      provider_message_id: provider_message_id,
      failed_at: now(),
      failure_class: failure_class
    })
  end

  defp update_reply(conversation, action, attrs) do
    actor = %{actor_type: :system, actor_id: "whatsapp_inbound_worker"}

    conversation
    |> Changeset.for_update(action, attrs, actor: actor)
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _conversation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail_stored_reply(conversation, pending_reply) do
    provider_message_id = pending_reply["provider_message_id"]

    if is_binary(provider_message_id) and provider_message_id != "" do
      case mark_reply_failed(
             conversation,
             provider_message_id,
             "whatsapp_reply_ciphertext_invalid"
           ) do
        :ok -> {:discard, :whatsapp_reply_failed}
        {:error, _reason} -> {:error, :whatsapp_reply_checkpoint_failed}
      end
    else
      {:discard, :whatsapp_reply_failed}
    end
  end

  defp unresolved_pending_reply(%{state_data: state_data}) when is_map(state_data) do
    case Map.get(state_data, "pending_reply") do
      %{"status" => status, "ciphertext" => ciphertext} = pending_reply
      when status in @unresolved_reply_statuses and is_binary(ciphertext) and ciphertext != "" ->
        {:ok, pending_reply}

      %{"status" => status} = pending_reply when status in @unresolved_reply_statuses ->
        {:invalid, pending_reply}

      _ ->
        :none
    end
  end

  defp unresolved_pending_reply(_conversation), do: :none

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts),
       do: attempt >= max_attempts

  defp final_attempt?(_job), do: false

  defp permanent_failure_class(%{status: :auth_error}),
    do: "whatsapp_reply_auth_failure"

  defp permanent_failure_class(%{status: :validation_error}),
    do: "whatsapp_reply_validation_failure"

  defp permanent_failure_class(_response), do: "whatsapp_reply_failed"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp command_from_args(args, conversation, text_body) do
    %MessageCommand{
      provider: "meta",
      provider_message_id: Map.fetch!(args, "provider_message_id"),
      phone_e164: conversation.phone_e164,
      wa_id: conversation.wa_id,
      message_type: Map.get(args, "message_type", "text"),
      text_body: text_body,
      received_at: parse_received_at(Map.get(args, "received_at")),
      raw_payload_hash: Map.get(args, "raw_payload_hash", ""),
      correlation_id: Map.get(args, "correlation_id"),
      metadata: %{}
    }
  end

  defp parse_received_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp parse_received_at(_value), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp redact_phone(nil), do: nil

  defp redact_phone(value) when is_binary(value),
    do: FastCheck.Observability.Redactor.redact_phone(value)

  defp stringify_keys(args) do
    Map.new(args, fn {key, value} ->
      key =
        if is_atom(key),
          do: Atom.to_string(key),
          else: key

      {key, value}
    end)
  end

  defp load_conversation(id) do
    id = normalize_id(id)

    Conversation
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :conversation_not_found}
      other -> other
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp provider_hash(nil), do: nil

  defp provider_hash(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end
