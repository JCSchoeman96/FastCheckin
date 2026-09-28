defmodule FastCheck.Workers.SendWhatsAppTicketLinkWorker do
  @moduledoc """
  Sends one secure ticket page link using a durable ticket delivery intent.

  The intent is the authority for the order, issued ticket, conversation, and
  resend challenge. Redis is not used to decide whether a customer may receive
  another initial delivery.
  """

  import Ecto.Query, only: [from: 2]

  use Oban.Worker,
    queue: :whatsapp_outbound,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:ticket_delivery_intent_id]]

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.Client
  alias FastCheck.Messaging.WhatsApp.Dedupe
  alias FastCheck.Messaging.WhatsApp.DeliveryPolicy
  alias FastCheck.Messaging.WhatsApp.OutboundDeliveryPolicy
  alias FastCheck.Messaging.WhatsApp.TicketLinkRenderer
  alias FastCheck.Observability.Redactor
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.DeliveryAttempt
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.TicketDeliveryIntent
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Sales.TicketPage
  alias FastCheck.Sales.TicketResendChallenge
  alias FastCheck.Tickets.DeliveryToken

  @intent_terminal_states ["provider_accepted", "fallback_required", "cancelled"]
  @attempt_acceptance_states ["provider_accepted", "sent", "delivered", "read"]
  @dispatch_recovery_window_seconds 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ticket_delivery_intent_id" => id} = args} = job)
      when map_size(args) == 1 do
    with {:ok, intent_id} <- positive_id(id),
         {:ok, _intent} <- load_intent(intent_id),
         {:ok, prepared} <- prepare_attempt(intent_id, job),
         :ok <- execute_prepared(prepared, job) do
      :ok
    else
      {:stop, reason} -> {:discard, reason}
      {:retry, classification} -> {:error, %{retryable?: true, classification: classification}}
      {:error, :intent_not_found} -> {:discard, :intent_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, :invalid_args}

  # Attempt allocation and intent inspection share one short transaction. The
  # row lock serializes duplicate executions and attempt_number allocation.
  # The transaction is committed before any token rotation or provider call.
  defp prepare_attempt(intent_id, job) do
    Repo.transaction(fn ->
      case lock_intent(intent_id) do
        nil -> Repo.rollback(:intent_not_found)
        locked_intent -> prepare_locked_intent(locked_intent, job)
      end
    end)
    |> case do
      {:ok, {:retry, classification}} -> {:retry, classification}
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_locked_intent(%{status: "provider_accepted", id: id}, _job) do
    case load_intent(id) do
      {:ok, intent} -> {:recover_acceptance, resend_challenge_id(intent)}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare_locked_intent(%{status: status}, _job) when status in @intent_terminal_states do
    {:stop, :already_terminal}
  end

  defp prepare_locked_intent(locked_intent, job) do
    with {:ok, intent} <- load_intent(locked_intent.id),
         {:ok, attempts} <- load_intent_attempts(intent.id) do
      cond do
        acceptance_evidence?(attempts) ->
          recover_accepted_intent(intent)

        intent.status == "manual_review" ->
          {:stop, :manual_review}

        dispatching_attempt =
            Enum.find(attempts, &(whatsapp_meta_attempt?(&1) and &1.status == "dispatching")) ->
          resolve_dispatching_attempt(intent, dispatching_attempt, job)

        Enum.any?(attempts, &(whatsapp_meta_attempt?(&1) and &1.status == "manual_review")) ->
          review_ambiguous_intent(intent)

        true ->
          prepare_new_attempt(intent)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resolve_dispatching_attempt(intent, attempt, job) do
    if max_worker_attempt_reached?(job) or dispatch_recovery_window_expired?(attempt) do
      review_ambiguous_dispatch(intent, attempt)
    else
      {:retry, "dispatch_in_progress"}
    end
  end

  defp dispatch_recovery_window_expired?(%{updated_at: %DateTime{} = updated_at}) do
    DateTime.diff(DateTime.utc_now(), updated_at, :second) >=
      @dispatch_recovery_window_seconds
  end

  defp dispatch_recovery_window_expired?(%{updated_at: %NaiveDateTime{} = updated_at}) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), updated_at, :second) >=
      @dispatch_recovery_window_seconds
  end

  defp dispatch_recovery_window_expired?(_attempt), do: true

  defp recover_accepted_intent(intent) do
    case mark_intent_provider_accepted(intent) do
      :ok -> {:recover_acceptance, resend_challenge_id(intent)}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp review_ambiguous_dispatch(intent, attempt) do
    with :ok <- mark_attempt_manual_review(attempt.id, "ambiguous_transport_outcome"),
         :ok <- mark_intent_manual_review(intent, "ambiguous_transport_outcome") do
      {:stop, :manual_review}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp review_ambiguous_intent(intent) do
    case mark_intent_manual_review(intent, "ambiguous_transport_outcome") do
      :ok -> {:stop, :manual_review}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare_new_attempt(intent) do
    with {:ok, bundle} <- load_and_validate_bundle(intent),
         decision <- DeliveryPolicy.select_ticket_delivery(bundle.conversation),
         {:ok, attempt} <- create_delivery_attempt(intent, bundle, decision),
         {:ok, prepared} <- prepare_transport_attempt(attempt, intent, bundle, decision) do
      prepared
    else
      {:unsafe, reason} ->
        cancel_unsafe_intent(intent, reason)

      {:invalid, reason} ->
        review_invalid_intent(intent, reason)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp cancel_unsafe_intent(intent, reason) do
    case mark_intent_cancelled(intent, reason) do
      :ok -> {:stop, :ticket_not_deliverable}
      {:error, update_reason} -> Repo.rollback(update_reason)
    end
  end

  defp review_invalid_intent(intent, reason) do
    case mark_intent_manual_review(intent, reason) do
      :ok -> {:stop, :manual_review}
      {:error, update_reason} -> Repo.rollback(update_reason)
    end
  end

  defp prepare_transport_attempt(attempt, intent, _bundle, %{mode: :fallback_required} = decision) do
    with {:ok, _attempt} <-
           mark_fallback_required(
             attempt,
             decision.failure_reason,
             decision.fallback_channel
           ),
         :ok <- mark_intent_fallback_required(intent, "whatsapp_fallback_required") do
      {:ok, {:stop, :fallback_required}}
    end
  end

  defp prepare_transport_attempt(attempt, _intent, bundle, decision) do
    case mark_dispatching(attempt) do
      {:ok, attempt} -> {:ok, {:send, attempt, Map.put(bundle, :decision, decision)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_prepared({:stop, reason}, _job), do: {:stop, reason}

  defp execute_prepared({:recover_acceptance, challenge_id}, _job) do
    recover_resend_challenge_consumption(challenge_id)
  end

  defp execute_prepared({:send, attempt, bundle}, job) do
    with :ok <- claim_dedupe_optimization(bundle.intent),
         token <- DeliveryToken.generate(),
         {:ok, _ticket_issue} <- rotate_token(bundle.ticket_issue, token),
         :ok <- ensure_secure_page_valid(token.token),
         url <- ticket_url(token.token),
         result <- deliver(attempt, bundle.conversation, bundle.decision, url),
         :ok <- persist_provider_result(result, attempt, bundle.intent, job) do
      :ok
    else
      {:error, :ticket_not_deliverable} ->
        case persist_manual_review(
               attempt.id,
               bundle.intent.id,
               "secure_ticket_page_invalid",
               attempt_failure: "secure_ticket_page_invalid"
             ) do
          :ok -> {:stop, :ticket_not_deliverable}
          {:error, _reason} -> {:error, :delivery_attempt_persistence_failed}
        end

      other ->
        other
    end
  end

  defp deliver(attempt, conversation, %{mode: :session_message}, url) do
    body = TicketLinkRenderer.ticket_link(conversation.preferred_language, url)

    Client.send_text(conversation.phone_e164, body, correlation_id: attempt.correlation_id)
  end

  defp deliver(
         attempt,
         conversation,
         %{mode: :template_message, template_key: template_key, template: template},
         url
       ) do
    Client.send_template(
      conversation.phone_e164,
      template_key,
      template.language_code,
      ticket_link_template_components(url),
      correlation_id: attempt.correlation_id
    )
  end

  defp persist_provider_result({:ok, response}, attempt, intent, _job) do
    case persist_acceptance(attempt.id, intent.id, response.provider_message_id) do
      :ok -> recover_resend_challenge_consumption(resend_challenge_id(intent))
      {:error, _reason} = error -> error
    end
  end

  defp persist_provider_result({:error, reason}, attempt, intent, job) do
    case OutboundDeliveryPolicy.classify(reason) do
      :safe_retry ->
        persist_safe_retry(attempt, intent, job)

      :ambiguous_manual_review ->
        persist_classified_review(attempt, intent, "ambiguous_transport_outcome")

      :permanent_manual_review ->
        persist_classified_review(attempt, intent, "permanent_transport_failure")
    end
  end

  defp persist_safe_retry(attempt, intent, job) do
    if max_worker_attempt_reached?(job) do
      case persist_exhausted_safe_retry(attempt.id, intent.id) do
        :ok -> {:stop, :manual_review}
        {:error, _reason} -> {:error, :delivery_attempt_persistence_failed}
      end
    else
      case mark_failed(attempt, "safe_retryable_transport_failure") do
        {:ok, _attempt} ->
          release_dedupe_optimization(intent)
          {:retry, "safe_retryable_transport_failure"}

        {:error, _reason} ->
          {:error, :delivery_attempt_persistence_failed}
      end
    end
  end

  defp persist_classified_review(attempt, intent, reason) do
    case persist_manual_review(
           attempt.id,
           intent.id,
           reason,
           attempt_failure: reason
         ) do
      :ok -> {:stop, :manual_review}
      {:error, _reason} -> {:error, :delivery_attempt_persistence_failed}
    end
  end

  defp persist_acceptance(attempt_id, intent_id, provider_message_id) do
    Repo.transaction(fn ->
      lock_delivery_attempt_authority!(intent_id, attempt_id)

      with {:ok, attempt} <- load_attempt(attempt_id),
           {:ok, intent} <- load_intent(intent_id),
           {:ok, _attempt} <- mark_ticket_provider_accepted(attempt, provider_message_id),
           :ok <- mark_intent_provider_accepted(intent) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction()
  end

  defp lock_delivery_attempt_authority!(intent_id, attempt_id) do
    case Repo.one(
           from i in "sales_ticket_delivery_intents",
             where: i.id == ^intent_id,
             lock: "FOR UPDATE",
             select: i.id
         ) do
      nil -> Repo.rollback(:intent_not_found)
      _id -> :ok
    end

    case Repo.one(
           from d in "sales_delivery_attempts",
             where: d.id == ^attempt_id and d.ticket_delivery_intent_id == ^intent_id,
             lock: "FOR UPDATE",
             select: d.id
         ) do
      nil -> Repo.rollback(:delivery_attempt_not_found)
      _id -> :ok
    end
  end

  defp persist_manual_review(attempt_id, intent_id, reason, opts) do
    Repo.transaction(fn ->
      lock_delivery_attempt_authority!(intent_id, attempt_id)

      with {:ok, attempt} <- load_attempt(attempt_id),
           {:ok, intent} <- load_intent(intent_id),
           :ok <- mark_delivery_manual_review(attempt, intent, reason, opts) do
        :ok
      else
        {:error, failure} -> Repo.rollback(failure)
      end
    end)
    |> normalize_transaction()
  end

  defp persist_exhausted_safe_retry(attempt_id, intent_id) do
    Repo.transaction(fn ->
      lock_delivery_attempt_authority!(intent_id, attempt_id)

      with {:ok, attempt} <- load_attempt(attempt_id),
           {:ok, intent} <- load_intent(intent_id),
           :ok <- mark_exhausted_safe_retry(attempt, intent) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction()
  end

  defp mark_delivery_manual_review(attempt, intent, reason, opts) do
    cond do
      intent.status == "provider_accepted" ->
        :ok

      accepted_attempt?(attempt) ->
        mark_intent_provider_accepted(intent)

      true ->
        with :ok <-
               mark_attempt_manual_review_idempotently(
                 attempt,
                 Keyword.fetch!(opts, :attempt_failure)
               ),
             do: mark_intent_manual_review(intent, reason)
    end
  end

  defp mark_exhausted_safe_retry(attempt, intent) do
    cond do
      intent.status == "provider_accepted" ->
        :ok

      accepted_attempt?(attempt) ->
        mark_intent_provider_accepted(intent)

      intent.status == "manual_review" or attempt.status == "manual_review" ->
        reason = intent.failure_reason || "safe_transport_retries_exhausted"

        with :ok <- mark_attempt_manual_review_idempotently(attempt, reason),
             do: mark_intent_manual_review(intent, reason)

      true ->
        with {:ok, _failed_attempt} <-
               mark_failed(attempt, "safe_retryable_transport_failure"),
             do: mark_intent_manual_review(intent, "safe_transport_retries_exhausted")
    end
  end

  defp mark_attempt_manual_review_idempotently(
         %DeliveryAttempt{status: "manual_review"},
         _reason
       ),
       do: :ok

  defp mark_attempt_manual_review_idempotently(attempt, reason) do
    case mark_manual_review(attempt, reason) do
      {:ok, _attempt} -> :ok
      {:error, failure} -> {:error, failure}
    end
  end

  defp accepted_attempt?(attempt) do
    attempt.status in @attempt_acceptance_states or
      usable_provider_message_id?(attempt.provider_message_id)
  end

  defp create_delivery_attempt(intent, bundle, decision) do
    attempt_number =
      Repo.one(
        from d in "sales_delivery_attempts",
          where: d.ticket_delivery_intent_id == ^intent.id,
          select: coalesce(max(d.attempt_number), 0)
      ) + 1

    attrs = %{
      sales_order_id: intent.sales_order_id,
      ticket_issue_id: intent.ticket_issue_id,
      ticket_delivery_intent_id: intent.id,
      ticket_resend_challenge_id: intent.ticket_resend_challenge_id,
      channel: "whatsapp",
      provider: "meta",
      recipient: Redactor.redact_phone(bundle.conversation.phone_e164),
      delivery_reason: delivery_reason(intent),
      template_name: template_name(decision),
      within_whatsapp_window: decision.within_whatsapp_window,
      attempt_number: attempt_number,
      correlation_id: "ticket-delivery-#{intent.id}-attempt-#{attempt_number}"
    }

    DeliveryAttempt
    |> Changeset.for_create(:create_queued, attrs, actor: system_actor())
    |> ash_create()
  end

  defp load_and_validate_bundle(intent) do
    with {:ok, issue} <- load_ticket_issue(intent.ticket_issue_id),
         {:ok, order} <- load_order(intent.sales_order_id),
         {:ok, conversation} <- load_conversation(intent.conversation_id),
         {:ok, challenge} <- maybe_load_resend_challenge(intent) do
      bundle = %{
        intent: intent,
        ticket_issue: issue,
        order: order,
        conversation: conversation,
        challenge: challenge
      }

      case validate_bundle(bundle) do
        :ok -> {:ok, bundle}
        {:unsafe, reason} -> {:unsafe, reason}
        {:invalid, reason} -> {:invalid, reason}
      end
    else
      {:error, _reason} -> {:invalid, "ticket_delivery_relationship_conflict"}
    end
  end

  defp validate_bundle(bundle) do
    with :ok <- validate_authority_relationships(bundle),
         :ok <- validate_ticket_deliverability(bundle) do
      validate_delivery_purpose(bundle)
    end
  end

  defp validate_authority_relationships(%{
         intent: intent,
         ticket_issue: issue,
         order: order,
         conversation: conversation
       }) do
    cond do
      issue.sales_order_id != intent.sales_order_id ->
        {:invalid, "ticket_delivery_relationship_conflict"}

      order.id != intent.sales_order_id ->
        {:invalid, "ticket_delivery_relationship_conflict"}

      conversation.id != intent.conversation_id ->
        {:invalid, "ticket_delivery_relationship_conflict"}

      true ->
        :ok
    end
  end

  defp validate_ticket_deliverability(%{order: order, ticket_issue: issue}) do
    cond do
      order.status != "ticket_issued" ->
        {:unsafe, "ticket_or_order_not_deliverable"}

      issue.status != "issued" or not is_nil(issue.revoked_at) ->
        {:unsafe, "ticket_or_order_not_deliverable"}

      true ->
        :ok
    end
  end

  defp validate_delivery_purpose(%{intent: %{purpose: "initial_ticket_delivery"}} = bundle),
    do: validate_initial_delivery_authority(bundle)

  defp validate_delivery_purpose(%{intent: intent, challenge: challenge})
       when intent.purpose == "verified_ticket_resend" do
    if valid_resend_challenge?(intent, challenge),
      do: :ok,
      else: {:invalid, "ticket_delivery_resend_challenge_invalid"}
  end

  defp validate_delivery_purpose(_bundle),
    do: {:invalid, "ticket_delivery_purpose_invalid"}

  defp validate_initial_delivery_authority(%{
         intent: intent,
         order: order,
         conversation: conversation,
         challenge: challenge
       }) do
    cond do
      not is_nil(challenge) ->
        {:invalid, "ticket_delivery_relationship_conflict"}

      order.sales_conversation_id != intent.conversation_id ->
        {:invalid, "ticket_delivery_relationship_conflict"}

      order.source_channel != "whatsapp" ->
        {:invalid, "ticket_delivery_relationship_conflict"}

      conversation.phone_e164 != order.buyer_phone ->
        {:invalid, "ticket_delivery_relationship_conflict"}

      true ->
        :ok
    end
  end

  defp valid_resend_challenge?(intent, %TicketResendChallenge{} = challenge) do
    intent.ticket_resend_challenge_id == challenge.id and
      challenge.status == "verified" and is_nil(challenge.consumed_at) and
      challenge.conversation_id == intent.conversation_id and
      challenge.sales_order_id == intent.sales_order_id and
      challenge.ticket_issue_id == intent.ticket_issue_id
  end

  defp valid_resend_challenge?(_intent, _challenge), do: false

  defp maybe_load_resend_challenge(%{
         purpose: "initial_ticket_delivery",
         ticket_resend_challenge_id: nil
       }),
       do: {:ok, nil}

  defp maybe_load_resend_challenge(%{ticket_resend_challenge_id: challenge_id})
       when is_integer(challenge_id),
       do: load_resend_challenge(challenge_id)

  defp maybe_load_resend_challenge(_intent), do: {:error, :invalid_challenge}

  defp acceptance_evidence?(attempts) do
    Enum.any?(attempts, fn attempt ->
      whatsapp_meta_attempt?(attempt) and
        (attempt.status in @attempt_acceptance_states or
           usable_provider_message_id?(attempt.provider_message_id))
    end)
  end

  defp whatsapp_meta_attempt?(%{provider: "meta", channel: "whatsapp"}), do: true
  defp whatsapp_meta_attempt?(_attempt), do: false

  defp load_intent_attempts(intent_id) do
    Repo.all(
      from d in "sales_delivery_attempts",
        where: d.ticket_delivery_intent_id == ^intent_id,
        order_by: [asc: d.attempt_number, asc: d.id],
        select: map(d, [:id, :status, :provider_message_id, :provider, :channel, :updated_at])
    )
    |> then(&{:ok, &1})
  end

  defp lock_intent(intent_id) do
    Repo.one(
      from i in "sales_ticket_delivery_intents",
        where: i.id == ^intent_id,
        lock: "FOR UPDATE",
        select: map(i, [:id, :status])
    )
  end

  defp load_intent(id),
    do: read_one(TicketDeliveryIntent, :get_by_id, %{id: id}, :intent_not_found)

  defp load_order(id), do: read_one(Order, :get_by_id, %{id: id}, :order_not_found)

  defp load_ticket_issue(id),
    do: read_one(TicketIssue, :get_by_id, %{id: id}, :ticket_issue_not_found)

  defp load_conversation(id),
    do: read_one(Conversation, :get_by_id, %{id: id}, :conversation_not_found)

  defp load_resend_challenge(id),
    do: read_one(TicketResendChallenge, :get_by_id, %{id: id}, :resend_challenge_not_found)

  defp read_one(resource, action, args, not_found) do
    resource
    |> Query.for_read(action, args)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, not_found}
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_dispatching(attempt) do
    attempt
    |> Changeset.for_update(:mark_dispatching, %{}, actor: system_actor())
    |> ash_update()
  end

  defp mark_ticket_provider_accepted(attempt, provider_message_id) do
    attempt
    |> Changeset.for_update(
      :mark_ticket_provider_accepted,
      %{
        provider_message_id: provider_message_id,
        provider_accepted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      actor: system_actor()
    )
    |> ash_update()
  end

  defp mark_failed(attempt, safe_reason) do
    attempt
    |> Changeset.for_update(
      :mark_failed,
      %{
        provider_error_code: "whatsapp_send_retryable",
        provider_error_message: "whatsapp send failed",
        failure_reason: safe_reason
      },
      actor: system_actor()
    )
    |> ash_update()
  end

  defp mark_manual_review(attempt, safe_reason) do
    attempt
    |> Changeset.for_update(
      :mark_manual_review,
      %{
        provider_error_code: "whatsapp_send_requires_review",
        provider_error_message: "whatsapp send requires review",
        failure_reason: safe_reason,
        fallback_channel: "manual_review"
      },
      actor: system_actor()
    )
    |> ash_update()
  end

  defp mark_fallback_required(attempt, reason, fallback_channel) do
    attempt
    |> Changeset.for_update(
      :mark_fallback_required,
      %{
        provider_error_code: "whatsapp_delivery_fallback_required",
        provider_error_message: "whatsapp delivery fallback required",
        failure_reason: safe_classification(reason),
        fallback_channel: fallback_channel
      },
      actor: system_actor()
    )
    |> ash_update()
  end

  defp mark_intent_provider_accepted(%TicketDeliveryIntent{status: "provider_accepted"}), do: :ok

  defp mark_intent_provider_accepted(intent) do
    case intent
         |> Changeset.for_update(:mark_provider_accepted, %{}, actor: system_actor())
         |> ash_update() do
      {:ok, _intent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_intent_manual_review(%TicketDeliveryIntent{status: "manual_review"}, _reason), do: :ok

  defp mark_intent_manual_review(intent, reason) do
    update_intent(intent, :mark_manual_review, %{failure_reason: reason})
  end

  defp mark_intent_fallback_required(intent, reason) do
    update_intent(intent, :mark_fallback_required, %{failure_reason: reason})
  end

  defp mark_intent_cancelled(intent, reason) do
    update_intent(intent, :mark_cancelled, %{failure_reason: reason})
  end

  defp update_intent(intent, action, attrs) do
    case intent
         |> Changeset.for_update(action, attrs, actor: system_actor())
         |> ash_update() do
      {:ok, _intent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_attempt_manual_review(attempt_id, reason) do
    with {:ok, attempt} <- load_attempt(attempt_id),
         {:ok, _attempt} <- mark_manual_review(attempt, reason) do
      :ok
    end
  end

  defp load_attempt(id),
    do: read_one(DeliveryAttempt, :get_by_id, %{id: id}, :delivery_attempt_not_found)

  defp recover_resend_challenge_consumption(nil), do: :ok

  defp recover_resend_challenge_consumption(challenge_id) when is_integer(challenge_id) do
    Repo.transaction(fn ->
      case Repo.one(
             from c in "sales_ticket_resend_challenges",
               where: c.id == ^challenge_id,
               lock: "FOR UPDATE",
               select: map(c, [:id, :status, :consumed_at])
           ) do
        %{status: "verified", consumed_at: nil} ->
          with {:ok, challenge} <- load_resend_challenge(challenge_id),
               {:ok, _challenge} <- consume_challenge(challenge) do
            :ok
          else
            {:error, reason} -> Repo.rollback(reason)
          end

        _already_unavailable_or_consumed ->
          :ok
      end
    end)
    |> normalize_transaction()
  end

  defp consume_challenge(challenge) do
    challenge
    |> Changeset.for_update(
      :mark_consumed,
      %{consumed_at: DateTime.utc_now() |> DateTime.truncate(:second)},
      actor: system_actor()
    )
    |> ash_update()
  end

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
        correlation_id: "ticket-delivery-#{ticket_issue.id}"
      },
      return_notifications?: true
    )
    |> normalize_ash_result()
  end

  defp ensure_secure_page_valid(token) do
    case TicketPage.resolve(token) do
      %{state: :valid} -> :ok
      _ -> {:error, :ticket_not_deliverable}
    end
  end

  defp ticket_url(token), do: FastCheckWeb.Endpoint.url() <> "/t/" <> token

  defp ticket_link_template_components(url) do
    [
      %{
        "type" => "body",
        "parameters" => [%{"type" => "text", "text" => url}]
      }
    ]
  end

  defp template_name(%{template: %{name: name}}), do: name
  defp template_name(_decision), do: nil

  defp delivery_reason(%{purpose: "initial_ticket_delivery"}), do: "initial_ticket_delivery"
  defp delivery_reason(%{purpose: "verified_ticket_resend"}), do: "verified_ticket_resend"

  defp claim_dedupe_optimization(%TicketDeliveryIntent{} = intent) do
    result =
      case intent do
        %{
          purpose: "verified_ticket_resend",
          conversation_id: conversation_id,
          ticket_issue_id: ticket_issue_id,
          ticket_resend_challenge_id: challenge_id
        }
        when is_integer(challenge_id) ->
          Dedupe.claim_send_ticket_link_for_challenge(
            conversation_id,
            ticket_issue_id,
            challenge_id,
            ticket_delivery_dedupe_ttl_seconds(),
            FastCheck.Redix
          )

        _initial ->
          Dedupe.claim_send_ticket_link(
            intent.conversation_id,
            intent.ticket_issue_id,
            ticket_delivery_dedupe_ttl_seconds()
          )
      end

    # Redis only records a best-effort hint. Database intent and attempt state
    # remains the authority even when a key is absent, duplicated, or expired.
    case result do
      {:ok, _claim} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp release_dedupe_optimization(%TicketDeliveryIntent{} = intent) do
    case intent do
      %{
        purpose: "verified_ticket_resend",
        conversation_id: conversation_id,
        ticket_issue_id: ticket_issue_id,
        ticket_resend_challenge_id: challenge_id
      }
      when is_integer(challenge_id) ->
        Dedupe.release_send_ticket_link_for_challenge(
          conversation_id,
          ticket_issue_id,
          challenge_id,
          FastCheck.Redix
        )

      _initial ->
        Dedupe.release_send_ticket_link(intent.conversation_id, intent.ticket_issue_id)
    end
  end

  defp ticket_delivery_dedupe_ttl_seconds do
    Application.get_env(:fastcheck, :whatsapp_ticket_delivery_dedupe_ttl_seconds, 86_400)
  end

  defp resend_challenge_id(%{purpose: "verified_ticket_resend", ticket_resend_challenge_id: id}),
    do: id

  defp resend_challenge_id(_intent), do: nil

  defp max_worker_attempt_reached?(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts),
       do: attempt >= max_attempts

  defp max_worker_attempt_reached?(_job), do: false

  defp usable_provider_message_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp usable_provider_message_id?(_id), do: false

  defp safe_classification(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_classification(_value), do: "whatsapp_delivery_failure"

  defp normalize_transaction({:ok, :ok}), do: :ok
  defp normalize_transaction({:ok, result}), do: result
  defp normalize_transaction({:error, reason}), do: {:error, reason}

  defp ash_create(changeset) do
    changeset
    |> Ash.create(authorize?: false, return_notifications?: true)
    |> normalize_ash_result()
  end

  defp ash_update(changeset) do
    changeset
    |> Ash.update(authorize?: false, return_notifications?: true)
    |> normalize_ash_result()
  end

  defp normalize_ash_result({:ok, record, notifications}) do
    Ash.Notifier.notify(notifications)
    {:ok, record}
  end

  defp normalize_ash_result({:ok, record}), do: {:ok, record}
  defp normalize_ash_result({:error, reason}), do: {:error, reason}

  defp positive_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp positive_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_args}
    end
  end

  defp positive_id(_id), do: {:error, :invalid_args}

  defp system_actor, do: %{actor_type: :system, actor_id: "send_whatsapp_ticket_link_worker"}
end
