defmodule FastCheckWeb.Webhooks.WhatsAppController do
  @moduledoc """
  Meta WhatsApp webhook ingress for FastCheck Sales.

  Verifies setup challenges and signed inbound payloads, then delegates to the
  minimal VS-17 dedupe/session/checkpoint/worker handoff.
  """

  use FastCheckWeb, :controller

  require Logger

  alias FastCheck.Messaging.WhatsApp.Config
  alias FastCheck.Messaging.WhatsApp.Dedupe
  alias FastCheck.Messaging.WhatsApp.InboundCheckpoint
  alias FastCheck.Messaging.WhatsApp.InboundNormalizer
  alias FastCheck.Messaging.WhatsApp.SessionStore
  alias FastCheck.Messaging.WhatsApp.WebhookVerifier
  alias FastCheck.Workers.WhatsAppInboundWorker

  def verify(conn, params) do
    with {:ok, config} <- Config.validate_for_webhook(),
         {:ok, challenge} <- WebhookVerifier.verify_challenge(params, config.verify_token) do
      send_resp(conn, 200, challenge)
    else
      {:error, %{status: :missing_config}} -> send_resp(conn, 503, "")
      {:error, :invalid_verify_token} -> send_resp(conn, 403, "")
      {:error, _reason} -> send_resp(conn, 400, "")
    end
  end

  def receive(conn, _params) do
    raw_body = Map.get(conn.private, :raw_body, "")
    signature = conn |> get_req_header("x-hub-signature-256") |> List.first()
    correlation_id = conn |> get_req_header("x-request-id") |> List.first()

    with {:ok, config} <- Config.validate_for_webhook(),
         :ok <- WebhookVerifier.verify_signature(raw_body, signature, config.app_secret),
         {:ok, payload} <- decode_json(raw_body),
         raw_payload_hash <- payload_hash(raw_body),
         {:ok, commands} <-
           InboundNormalizer.normalize(payload,
             raw_payload_hash: raw_payload_hash,
             correlation_id: correlation_id || Logger.metadata()[:request_id]
           ),
         :ok <- process_commands(commands, config) do
      send_resp(conn, 200, "")
    else
      {:error, %{status: :missing_config}} ->
        send_resp(conn, 503, "")

      {:error, :missing_signature} ->
        send_resp(conn, 401, "")

      {:error, :invalid_signature} ->
        send_resp(conn, 401, "")

      {:error, :malformed_payload} ->
        send_resp(conn, 400, "")

      {:error, :malformed_json} ->
        send_resp(conn, 400, "")

      {:error, :redis_unavailable} ->
        send_resp(conn, 503, "")

      {:error, _reason} ->
        send_resp(conn, 503, "")
    end
  end

  defp process_commands([], _config), do: :ok

  defp process_commands(commands, config) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      case process_command(command, config) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp process_command(command, config) do
    case Dedupe.claim_message(command.provider_message_id, config.dedupe_ttl_seconds) do
      {:ok, :duplicate} ->
        :ok

      {:ok, :new} ->
        case persist_and_enqueue(command, config) do
          :ok ->
            :ok

          {:error, reason} ->
            Dedupe.release_message(command.provider_message_id)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_and_enqueue(command, config) do
    with {:ok, conversation} <- InboundCheckpoint.checkpoint(command, config.session_ttl_seconds),
         :ok <- SessionStore.put_session(command, conversation, config.session_ttl_seconds),
         {:ok, _job} <- enqueue_worker(command, conversation) do
      :ok
    end
  end

  defp enqueue_worker(command, conversation) do
    WhatsAppInboundWorker.new(%{
      "provider_message_id" => command.provider_message_id,
      "wa_id_hash" => hash_id(command.wa_id),
      "phone_e164_redacted" => FastCheck.Observability.Redactor.redact_phone(command.phone_e164),
      "message_type" => command.message_type,
      "text_body_redacted_or_reference" => "[FILTERED_MESSAGE]",
      "conversation_id" => conversation.id,
      "correlation_id" => command.correlation_id,
      "received_at" => DateTime.to_iso8601(command.received_at),
      "raw_payload_hash" => command.raw_payload_hash
    })
    |> Oban.insert()
  end

  defp hash_id(nil), do: nil

  defp hash_id(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp decode_json(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed_json}
    end
  end

  defp payload_hash(raw_body) do
    :crypto.hash(:sha256, raw_body)
    |> Base.encode16(case: :lower)
  end
end
