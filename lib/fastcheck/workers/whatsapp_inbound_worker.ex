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

  alias Ash.Query
  alias FastCheck.Crypto
  alias FastCheck.Messaging.WhatsApp.Client
  alias FastCheck.Messaging.WhatsApp.ConversationStateMachine
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Observability.Correlation
  alias FastCheck.Sales.Conversation

  @impl Oban.Worker
  def new(args, opts) when is_map(args) and is_list(opts) do
    args
    |> sanitize_args()
    |> Oban.Job.new(Oban.Worker.merge_opts(__opts__(), opts))
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"conversation_id" => conversation_id} = args}) do
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
      handle_flow(args, conversation)
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

  defp handle_flow(args, conversation) do
    case decrypt_text_body(Map.get(args, "text_body_encrypted")) do
      {:ok, text_body} ->
        command = command_from_args(args, conversation, text_body)

        with {:ok, result} <- ConversationStateMachine.handle_inbound(command, conversation),
             :ok <- maybe_send_reply(conversation, command, result) do
          :ok
        else
          {:error, %{retryable?: true}} -> {:error, :whatsapp_send_retryable}
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

  defp maybe_send_reply(_conversation, _command, %{send_reply?: false}), do: :ok

  defp maybe_send_reply(conversation, command, result) do
    case Client.send_text(conversation.phone_e164, result.response_body,
           correlation_id: command.correlation_id
         ) do
      {:ok, _response} -> :ok
      {:error, response} -> {:error, response}
    end
  end

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
