defmodule FastCheck.Sales.Payments.WebhookIngestion do
  @moduledoc """
  Approved Sales Paystack webhook ingestion boundary.

  Verifies webhook signatures, dedupes provider deliveries, atomically persists
  `PaymentEvent` rows, and enqueues `PaystackWebhookWorker`. Does not verify
  transactions or mutate order/payment/ticket state.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Ash.Changeset
  alias Ecto.Multi
  alias FastCheck.Observability.Correlation
  alias FastCheck.Payments.Paystack.Config, as: PaystackConfig
  alias FastCheck.Payments.Paystack.EventDedupe
  alias FastCheck.Payments.Paystack.WebhookEventParser
  alias FastCheck.Payments.Paystack.WebhookVerifier
  alias FastCheck.Repo
  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.PaystackWebhookWorker

  @provider "paystack"

  @type ingest_result ::
          {:ok, :created | :duplicate, PaymentEvent.t()}
          | {:error, :invalid_signature | :malformed_payload | :webhook_disabled}
          | {:error, :transient, term()}

  @spec ingest(binary(), map() | String.t() | nil, keyword()) :: ingest_result()
  def ingest(raw_body, headers_or_signature, opts \\ [])

  def ingest(raw_body, headers, opts) when is_binary(raw_body) and is_map(headers) do
    context = build_context(opts)

    with {:ok, config} <- PaystackConfig.validate_for_webhook(),
         {:ok, :valid} <-
           WebhookVerifier.verify(raw_body, headers, secret_key: config.secret_key),
         payload_hash <- payload_hash(raw_body),
         {:ok, payload} <- decode_json(raw_body),
         {:ok, metadata} <- WebhookEventParser.parse(payload) do
      context =
        Map.merge(context, %{metadata: metadata, payload_hash: payload_hash})

      ingest_parsed(raw_body, payload, metadata, payload_hash, context)
    else
      {:error, %FastCheck.Payments.Paystack.Error{type: :missing_config}} ->
        {:error, :webhook_disabled}

      {:error, %FastCheck.Payments.Paystack.Error{type: :invalid_signature}} ->
        {:error, :invalid_signature}

      {:error, :malformed_json} ->
        {:error, :malformed_payload}

      {:error, :missing_event_type} ->
        {:error, :malformed_payload}

      {:error, reason} ->
        {:error, :transient, reason}
    end
  end

  def ingest(raw_body, signature_header, opts)
      when is_binary(raw_body) and (is_binary(signature_header) or is_nil(signature_header)) do
    ingest(raw_body, %{"x-paystack-signature" => signature_header}, opts)
  end

  def ingest(_raw_body, _headers_or_signature, _opts), do: {:error, :malformed_payload}

  defp ingest_parsed(_raw_body, payload, metadata, payload_hash, context) do
    attrs = build_attrs(metadata, payload_hash, payload, context)

    case redis_dedupe(metadata, payload_hash) do
      {:error, :duplicate} ->
        finish_duplicate(metadata, payload_hash, context, attrs)

      :ok ->
        case persist_and_enqueue(attrs) do
          {:ok, event} ->
            log_ingested(:created, event, metadata, payload_hash, context)
            {:ok, :created, event}

          {:error, :duplicate} ->
            finish_duplicate(metadata, payload_hash, context, attrs)

          {:error, reason} ->
            {:error, :transient, reason}
        end
    end
  end

  defp finish_duplicate(metadata, payload_hash, context, attrs) do
    case find_existing_event(metadata, payload_hash) do
      {:ok, event} ->
        case ensure_worker_job(event.id) do
          :ok ->
            log_ingested(:duplicate, event, metadata, payload_hash, context)
            {:ok, :duplicate, event}

          {:error, reason} ->
            {:error, :transient, reason}
        end

      {:error, :payment_event_not_found} ->
        release_dedupe(metadata, payload_hash)
        retry_orphaned_persist(metadata, payload_hash, context, attrs)

      {:error, reason} ->
        {:error, :transient, reason}
    end
  end

  defp retry_orphaned_persist(metadata, payload_hash, context, attrs) do
    case redis_dedupe(metadata, payload_hash) do
      {:error, :duplicate} ->
        finish_duplicate(metadata, payload_hash, context, attrs)

      :ok ->
        case persist_and_enqueue(attrs) do
          {:ok, event} ->
            log_ingested(:created, event, metadata, payload_hash, context)
            {:ok, :created, event}

          {:error, :duplicate} ->
            finish_duplicate(metadata, payload_hash, context, attrs)

          {:error, reason} ->
            {:error, :transient, reason}
        end
    end
  end

  defp release_dedupe(metadata, payload_hash) do
    metadata.provider_event_id
    |> EventDedupe.dedupe_key(payload_hash)
    |> EventDedupe.release()
  end

  defp build_context(opts) do
    %{
      correlation_id:
        Correlation.ensure_correlation_id(%{
          correlation_id: Keyword.get(opts, :correlation_id)
        })
    }
  end

  defp redis_dedupe(metadata, payload_hash) do
    key = EventDedupe.dedupe_key(metadata.provider_event_id, payload_hash)

    case EventDedupe.claim(key) do
      :ok -> :ok
      {:error, :duplicate} -> {:error, :duplicate}
      {:error, :redis_unavailable} -> :ok
    end
  end

  defp persist_and_enqueue(attrs) do
    changeset =
      PaymentEvent
      |> Changeset.for_create(:store_webhook_event, attrs)

    Multi.new()
    |> Multi.run(:payment_event, fn _repo, _changes ->
      case Ash.create(changeset,
             authorize?: false,
             domain: FastCheck.Sales,
             return_notifications?: true
           ) do
        {:ok, event, _notifications} -> {:ok, event}
        {:ok, event} -> {:ok, event}
        {:error, error} -> {:error, error}
      end
    end)
    |> Multi.run(:webhook_job, fn _repo, %{payment_event: event} ->
      PaystackWebhookWorker.new(%{"payment_event_id" => event.id})
      |> Oban.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{payment_event: event}} ->
        {:ok, event}

      {:error, :payment_event, %Ash.Error.Invalid{} = error, _changes} ->
        if unique_violation?(error), do: {:error, :duplicate}, else: {:error, error}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp find_existing_event(metadata, payload_hash) do
    read =
      if is_binary(metadata.provider_event_id) and metadata.provider_event_id != "" do
        PaymentEvent
        |> Ash.Query.for_read(:get_by_provider_event_id, %{
          provider: @provider,
          provider_event_id: metadata.provider_event_id
        })
      else
        PaymentEvent
        |> Ash.Query.for_read(:get_by_provider_payload_hash, %{
          provider: @provider,
          payload_hash: payload_hash
        })
      end

    case Ash.read_one(read, authorize?: false) do
      {:ok, %PaymentEvent{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :payment_event_not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp ensure_worker_job(payment_event_id) do
    if worker_job_exists?(payment_event_id) do
      :ok
    else
      case PaystackWebhookWorker.new(%{"payment_event_id" => payment_event_id})
           |> Oban.insert() do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp worker_job_exists?(payment_event_id) do
    worker = to_string(PaystackWebhookWorker)

    Repo.exists?(
      from j in Oban.Job,
        where: j.worker == ^worker,
        where: fragment("?->>'payment_event_id' = ?", j.args, ^to_string(payment_event_id)),
        where: j.state not in ["cancelled", "discarded"]
    )
  end

  defp unique_violation?(%Ash.Error.Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, fn
      %{message: message} when is_binary(message) ->
        String.contains?(message, "sales_payment_events_provider")

      _ ->
        false
    end)
  end

  defp unique_violation?(_), do: false

  defp build_attrs(metadata, payload_hash, payload, _context) do
    %{
      provider: @provider,
      provider_event_id: metadata.provider_event_id,
      provider_reference: metadata.provider_reference,
      event_type: metadata.event_type,
      signature_valid: true,
      payload_hash: payload_hash,
      raw_payload: payload,
      received_at: DateTime.utc_now() |> DateTime.truncate(:second),
      processing_status: "stored",
      processing_attempt_count: 0
    }
  end

  defp payload_hash(raw_body) do
    :crypto.hash(:sha256, raw_body)
    |> Base.encode16(case: :lower)
  end

  defp decode_json(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed_json}
    end
  end

  defp log_ingested(status, event, metadata, payload_hash, context) do
    Logger.info(
      "paystack_webhook_ingested",
      Correlation.operational_metadata(%{
        correlation_id: context.correlation_id,
        payment_event_id: event.id,
        provider: @provider,
        event_type: metadata.event_type,
        provider_reference: metadata.provider_reference,
        payload_hash: payload_hash,
        signature_valid: true,
        processing_status: event.processing_status,
        ingest_status: to_string(status)
      })
    )
  end
end
