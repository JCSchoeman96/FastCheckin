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
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation

  @unresolved_reply_statuses ["reply_pending", "reply_retryable"]
  @terminal_reply_statuses ["reply_sent", "reply_failed"]
  @active_oban_states ["available", "scheduled", "executing", "retryable"]
  @terminal_oban_states ["completed", "discarded", "cancelled"]
  @pending_reply_snooze_seconds 5
  @default_orphan_age_seconds 7 * 24 * 60 * 60
  @inbound_processing_key "inbound_processing"

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
      {:ok, pending_reply} ->
        if pending_reply_belongs_to_job?(pending_reply, args) do
          deliver_stored_reply(job, conversation, pending_reply)
        else
          recover_or_defer_inbound(job, args, conversation, pending_reply)
        end

      {:invalid, pending_reply} ->
        if pending_reply_belongs_to_job?(pending_reply, args) do
          fail_stored_reply(conversation, pending_reply)
        else
          recover_or_defer_inbound(job, args, conversation, pending_reply)
        end

      :none ->
        case inbound_processing(conversation) do
          {:ok, processing} ->
            if processing_claim_belongs_to_job?(processing, job) do
              process_fresh_inbound(job, args, conversation)
            else
              recover_or_defer_processing(job, args, conversation, processing)
            end

          {:invalid, _processing} ->
            defer_inbound_until_pending_reply_resolves()

          :none ->
            process_fresh_inbound(job, args, conversation)
        end
    end
  end

  defp pending_reply_belongs_to_job?(pending_reply, args) do
    provider_message_id = pending_reply["provider_message_id"]

    is_binary(provider_message_id) and provider_message_id != "" and
      provider_message_id == Map.get(args, "provider_message_id")
  end

  defp valid_pending_ciphertext?(%{"ciphertext" => ciphertext})
       when is_binary(ciphertext) and ciphertext != "",
       do: true

  defp valid_pending_ciphertext?(_pending_reply), do: false

  defp inbound_processing(%{state_data: state_data}) when is_map(state_data) do
    case Map.get(state_data, @inbound_processing_key) do
      %{"provider_message_id" => provider_message_id} = processing
      when is_binary(provider_message_id) and provider_message_id != "" ->
        {:ok, processing}

      nil ->
        :none

      processing ->
        {:invalid, processing}
    end
  end

  defp inbound_processing(_conversation), do: :none

  defp processing_claim_belongs_to_job?(%{"oban_job_id" => claim_job_id}, %Oban.Job{id: job_id})
       when is_integer(claim_job_id) and is_integer(job_id),
       do: claim_job_id == job_id

  defp processing_claim_belongs_to_job?(_processing, _job), do: false

  defp claim_inbound(conversation_id, provider_message_id, job)
       when is_integer(conversation_id) and is_binary(provider_message_id) and
              provider_message_id != "" do
    claim = inbound_claim(provider_message_id, job)

    # The row lock is held only while installing the durable claim. No provider
    # or business side effect runs inside this transaction.
    case Repo.transaction(fn -> claim_inbound_transaction(conversation_id, claim, job) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim_inbound(_conversation_id, _provider_message_id, _job),
    do: {:error, :invalid_inbound_claim}

  defp claim_inbound_transaction(conversation_id, claim, job) do
    case Repo.query(
           "SELECT state_data FROM sales_conversations WHERE id = $1 FOR UPDATE",
           [conversation_id]
         ) do
      {:ok, %{rows: [[state_data]]}} when is_map(state_data) ->
        cond do
          unresolved_reply_map?(Map.get(state_data, "pending_reply")) ->
            {:pending_reply, Map.get(state_data, "pending_reply")}

          processing_claim?(Map.get(state_data, @inbound_processing_key)) ->
            processing = Map.get(state_data, @inbound_processing_key)

            if processing_claim_belongs_to_job?(processing, job) do
              {:ok, :already_claimed}
            else
              {:inbound_processing, processing}
            end

          true ->
            new_state_data = Map.put(state_data, @inbound_processing_key, claim)

            Repo.query!(
              """
              UPDATE sales_conversations
              SET state_data = $1::jsonb, updated_at = now()
              WHERE id = $2
              """,
              [new_state_data, conversation_id]
            )

            {:ok, :claimed}
        end

      {:ok, %{rows: []}} ->
        Repo.rollback(:conversation_not_found)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp inbound_claim(provider_message_id, %Oban.Job{id: job_id}) do
    claim = %{
      "provider_message_id" => provider_message_id,
      "claimed_at" => DateTime.to_iso8601(now())
    }

    if is_integer(job_id), do: Map.put(claim, "oban_job_id", job_id), else: claim
  end

  defp unresolved_reply_map?(%{"status" => status}) when status in @unresolved_reply_statuses,
    do: true

  defp unresolved_reply_map?(%{"status" => status}) when status in @terminal_reply_statuses,
    do: false

  defp unresolved_reply_map?(%{}), do: true
  defp unresolved_reply_map?(_pending_reply), do: false

  defp processing_claim?(%{"provider_message_id" => provider_message_id})
       when is_binary(provider_message_id) and provider_message_id != "",
       do: true

  defp processing_claim?(nil), do: false
  defp processing_claim?(_processing), do: true

  defp clear_inbound_processing(conversation_id, provider_message_id)
       when is_integer(conversation_id) and is_binary(provider_message_id) and
              provider_message_id != "" do
    result =
      Repo.transaction(fn ->
        case Repo.query(
               "SELECT state_data FROM sales_conversations WHERE id = $1 FOR UPDATE",
               [conversation_id]
             ) do
          {:ok, %{rows: [[state_data]]}} when is_map(state_data) ->
            case Map.get(state_data, @inbound_processing_key) do
              %{"provider_message_id" => ^provider_message_id} ->
                state_data = Map.delete(state_data, @inbound_processing_key)

                Repo.query!(
                  """
                  UPDATE sales_conversations
                  SET state_data = $1::jsonb, updated_at = now()
                  WHERE id = $2
                  """,
                  [state_data, conversation_id]
                )

                :ok

              _other ->
                :ok
            end

          {:ok, %{rows: []}} ->
            Repo.rollback(:conversation_not_found)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_inbound_processing(_conversation_id, _provider_message_id),
    do: {:error, :invalid_inbound_claim}

  defp orphaned?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} ->
        DateTime.diff(DateTime.utc_now(), timestamp, :second) >= orphan_age_seconds()

      _ ->
        false
    end
  end

  defp orphaned?(_value), do: false

  defp orphaned_pending_reply?(pending_reply) when is_map(pending_reply) do
    orphaned?(pending_reply["computed_at"] || pending_reply["checkpointed_at"])
  end

  defp orphaned_pending_reply?(_pending_reply), do: false

  defp orphan_age_seconds do
    Application.get_env(
      :fastcheck,
      :whatsapp_inbound_orphan_age_seconds,
      @default_orphan_age_seconds
    )
  end

  defp defer_inbound_until_pending_reply_resolves,
    do: {:snooze, @pending_reply_snooze_seconds}

  defp recover_or_defer_inbound(job, args, conversation, pending_reply) do
    case pending_reply_job_state(conversation.id, pending_reply["provider_message_id"]) do
      {:ok, state} when state in @terminal_oban_states ->
        fail_pending_reply_and_process(job, args, conversation, pending_reply)

      {:ok, state} when state in @active_oban_states ->
        defer_inbound_until_pending_reply_resolves()

      :unknown ->
        if orphaned_pending_reply?(pending_reply) do
          fail_pending_reply_and_process(job, args, conversation, pending_reply)
        else
          defer_inbound_until_pending_reply_resolves()
        end

      {:error, _reason} ->
        defer_inbound_until_pending_reply_resolves()
    end
  end

  defp fail_pending_reply_and_process(job, args, conversation, pending_reply) do
    case mark_reply_failed(
           conversation,
           pending_reply["provider_message_id"],
           "whatsapp_reply_failed"
         ) do
      :ok ->
        case load_conversation(conversation.id) do
          {:ok, fresh_conversation} -> process_fresh_inbound(job, args, fresh_conversation)
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} ->
        {:error, :whatsapp_reply_checkpoint_failed}
    end
  end

  defp recover_or_defer_processing(job, args, conversation, processing) do
    provider_message_id = processing["provider_message_id"]

    case pending_reply_job_state(conversation.id, provider_message_id) do
      {:ok, state} when state in @terminal_oban_states ->
        clear_processing_and_process(job, args, conversation, provider_message_id)

      {:ok, state} when state in @active_oban_states ->
        defer_inbound_until_pending_reply_resolves()

      :unknown ->
        if orphaned?(processing["claimed_at"]) do
          clear_processing_and_process(job, args, conversation, provider_message_id)
        else
          defer_inbound_until_pending_reply_resolves()
        end

      {:error, _reason} ->
        defer_inbound_until_pending_reply_resolves()
    end
  end

  defp clear_processing_and_process(job, args, conversation, provider_message_id) do
    case clear_inbound_processing(conversation.id, provider_message_id) do
      :ok ->
        case load_conversation(conversation.id) do
          {:ok, fresh_conversation} -> process_fresh_inbound(job, args, fresh_conversation)
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} ->
        {:error, :whatsapp_inbound_checkpoint_failed}
    end
  end

  defp pending_reply_job_state(conversation_id, provider_message_id)
       when is_integer(conversation_id) and is_binary(provider_message_id) and
              provider_message_id != "" do
    case Repo.query(
           """
           SELECT state
           FROM oban_jobs
           WHERE worker = $1
             AND args->>'conversation_id' = $2
             AND args->>'provider_message_id' = $3
           ORDER BY inserted_at DESC, id DESC
           LIMIT 1
           """,
           [
             Oban.Worker.to_string(__MODULE__),
             Integer.to_string(conversation_id),
             provider_message_id
           ]
         ) do
      {:ok, %{rows: [[state]]}} -> {:ok, state}
      {:ok, %{rows: []}} -> :unknown
      {:error, reason} -> {:error, reason}
    end
  end

  defp pending_reply_job_state(_conversation_id, _provider_message_id), do: :unknown

  defp process_fresh_inbound(job, args, conversation) do
    provider_message_id = Map.get(args, "provider_message_id")

    case claim_inbound(conversation.id, provider_message_id, job) do
      {:ok, _claim_status} ->
        with {:ok, fresh_conversation} <- load_conversation(conversation.id) do
          process_claimed_inbound(job, args, fresh_conversation)
        end

      {:pending_reply, pending_reply} ->
        if pending_reply_belongs_to_job?(pending_reply, args) do
          if valid_pending_ciphertext?(pending_reply) do
            deliver_stored_reply(job, conversation, pending_reply)
          else
            fail_stored_reply(conversation, pending_reply)
          end
        else
          recover_or_defer_inbound(job, args, conversation, pending_reply)
        end

      {:inbound_processing, _processing} ->
        defer_inbound_until_pending_reply_resolves()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_claimed_inbound(job, args, conversation) do
    case decrypt_text_body(Map.get(args, "text_body_encrypted")) do
      {:ok, text_body} ->
        command = command_from_args(args, conversation, text_body)

        case ConversationStateMachine.handle_inbound(command, conversation) do
          {:ok, result} -> deliver_computed_reply(job, command, result)
          {:error, reason} -> {:error, reason}
        end

      :no_text ->
        clear_inbound_processing(conversation.id, Map.get(args, "provider_message_id"))

      {:error, _reason} ->
        {:error, :invalid_encrypted_text_body}
    end
  end

  defp decrypt_text_body(nil), do: :no_text
  defp decrypt_text_body(""), do: :no_text
  defp decrypt_text_body(value) when is_binary(value), do: Crypto.decrypt(value)

  defp deliver_computed_reply(
         _job,
         %MessageCommand{provider_message_id: provider_message_id},
         %{send_reply?: false, conversation: conversation}
       ) do
    clear_inbound_processing(conversation.id, provider_message_id)
  end

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

      %{"status" => status} when status in @terminal_reply_statuses ->
        :none

      %{} = pending_reply ->
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
