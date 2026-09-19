defmodule FastCheck.Messaging.WhatsApp.DeliveryStatusReconciler do
  @moduledoc """
  Correlates signed Meta delivery evidence to exactly one tracked attempt.

  The reconciler inserts immutable evidence before applying a projection
  through the DeliveryAttempt Ash lifecycle. It never creates an attempt for
  an unknown WAMID and never calls sales business logic.
  """

  import Ecto.Query, only: [from: 2]

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.ProviderStatus
  alias FastCheck.Repo
  alias FastCheck.Sales.DeliveryAttempt

  @success_rank %{"sent" => 1, "delivered" => 2, "read" => 3}
  @terminal_statuses ~w(fallback_required manual_review cancelled)

  @type result ::
          {:updated, String.t()}
          | {:conflict, :manual_review}
          | {:duplicate, String.t()}
          | {:ignored, atom()}
          | {:error, atom()}

  @spec reconcile(ProviderStatus.t()) :: result()
  def reconcile(%ProviderStatus{provider: "meta"} = event) do
    case Repo.transaction(fn -> reconcile_in_transaction(event) end) do
      {:ok, {result, notifications}} ->
        Ash.Notifier.notify(notifications)
        result

      {:ok, result} ->
        result

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :reconciliation_failed}
    end
  end

  def reconcile(%ProviderStatus{}), do: {:ignored, :unsupported_provider}

  defp reconcile_in_transaction(%ProviderStatus{} = event) do
    attempts =
      from(attempt in "sales_delivery_attempts",
        where:
          attempt.provider == "meta" and attempt.channel == "whatsapp" and
            attempt.provider_message_id == ^event.provider_message_id,
        select: %{
          id: attempt.id,
          status: attempt.status,
          provider_status: attempt.provider_status,
          provider_status_at: attempt.provider_status_at
        },
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    case attempts do
      [] ->
        {{:ignored, :unknown_wamid}, []}

      [attempt] ->
        case insert_evidence(event, attempt.id) do
          :duplicate ->
            {{:duplicate, event.status}, []}

          :inserted ->
            apply_projection(attempt, event)
        end

      _multiple ->
        Repo.rollback(:ambiguous_provider_message_id)
    end
  end

  defp insert_evidence(%ProviderStatus{} = event, attempt_id) do
    now = utc_now()

    attrs = %{
      delivery_attempt_id: attempt_id,
      provider: event.provider,
      channel: "whatsapp",
      provider_message_id: event.provider_message_id,
      provider_status: event.status,
      provider_status_at: event.provider_timestamp,
      provider_error_code: event.provider_error_code,
      raw_payload_hash: event.raw_payload_hash,
      correlation_id: event.correlation_id,
      inserted_at: now,
      updated_at: now
    }

    case Repo.insert_all(
           "sales_delivery_status_events",
           [attrs],
           on_conflict: :nothing,
           conflict_target: [
             :provider,
             :channel,
             :provider_message_id,
             :provider_status,
             :provider_status_at
           ]
         ) do
      {1, _rows} -> :inserted
      {0, _rows} -> :duplicate
    end
  end

  defp apply_projection(attempt, %ProviderStatus{} = event) do
    case transition(attempt, event) do
      :observational_status ->
        {{:ignored, :observational_status}, []}

      :out_of_order ->
        {{:ignored, :out_of_order}, []}

      {:update, action, attrs, status} ->
        {:ok, notifications} = update_projection!(attempt.id, action, attrs)
        {{:updated, status}, notifications}

      {:conflict, attrs} ->
        {:ok, notifications} =
          update_projection!(attempt.id, :mark_manual_review, attrs)

        {{:conflict, :manual_review}, notifications}
    end
  end

  defp update_projection!(attempt_id, action, attrs) do
    attempt =
      DeliveryAttempt
      |> Query.for_read(:get_by_id, %{id: attempt_id})
      |> Ash.read_one!(authorize?: false)

    case attempt
         |> Changeset.for_update(action, attrs, actor: system_actor())
         |> Ash.update(authorize?: false, return_notifications?: true) do
      {:ok, _updated, notifications} -> {:ok, notifications}
      {:ok, _updated} -> {:ok, []}
      {:error, _reason} -> Repo.rollback(:projection_update_failed)
    end
  end

  defp transition(%{status: status}, %ProviderStatus{status: "deleted"})
       when is_binary(status),
       do: :observational_status

  # A local mark_failed may retain the last accepted/sent provider status.
  # Keep that provenance distinct from an explicit Meta failed callback.
  defp transition(%{status: "failed", provider_status: nil}, %ProviderStatus{} = event),
    do: {:conflict, conflict_attrs(event)}

  defp transition(
         %{status: "failed", provider_status: provider_status},
         %ProviderStatus{status: "failed"}
       )
       when provider_status in ["accepted", "sent"],
       do: :observational_status

  defp transition(
         %{status: "failed", provider_status: provider_status},
         %ProviderStatus{} = event
       )
       when provider_status in ["accepted", "sent"],
       do: {:conflict, conflict_attrs(event)}

  defp transition(%{status: status}, _event) when status in @terminal_statuses,
    do: :observational_status

  defp transition(attempt, %ProviderStatus{status: incoming_status} = event)
       when incoming_status in ["sent", "delivered", "read"] do
    current_status = current_provider_status(attempt)
    current_rank = Map.get(@success_rank, current_status, 0)
    incoming_rank = Map.fetch!(@success_rank, incoming_status)

    cond do
      current_status == "failed" ->
        if later_or_equal?(event.provider_timestamp, attempt.provider_status_at),
          do: {:conflict, conflict_attrs(event)},
          else: :out_of_order

      incoming_rank <= current_rank ->
        :out_of_order

      current_status in [nil, "accepted"] ->
        if later_or_equal?(event.provider_timestamp, attempt.provider_status_at),
          do: success_update(incoming_status, event.provider_timestamp),
          else: :out_of_order

      is_nil(attempt.provider_status_at) ->
        success_update(incoming_status, event.provider_timestamp)

      later_or_equal?(event.provider_timestamp, attempt.provider_status_at) ->
        success_update(incoming_status, event.provider_timestamp)

      true ->
        :out_of_order
    end
  end

  defp transition(attempt, %ProviderStatus{status: "failed"} = event) do
    current_status = current_provider_status(attempt)

    cond do
      current_status in ["delivered", "read"] ->
        if later_or_equal?(event.provider_timestamp, attempt.provider_status_at),
          do: {:conflict, conflict_attrs(event)},
          else: :out_of_order

      current_status == "failed" ->
        :out_of_order

      current_status in [nil, "accepted", "sent"] ->
        if later_or_equal?(event.provider_timestamp, attempt.provider_status_at),
          do: {:update, :mark_provider_failed, failure_attrs(event), "failed"},
          else: :out_of_order

      true ->
        :out_of_order
    end
  end

  defp transition(_attempt, _event), do: :out_of_order

  defp success_update("sent", timestamp),
    do: {:update, :mark_sent, %{sent_at: timestamp}, "sent"}

  defp success_update("delivered", timestamp),
    do: {:update, :mark_delivered, %{delivered_at: timestamp}, "delivered"}

  defp success_update("read", timestamp),
    do: {:update, :mark_read, %{read_at: timestamp}, "read"}

  defp failure_attrs(%ProviderStatus{} = event) do
    %{
      provider_error_code: event.provider_error_code,
      failed_at: event.provider_timestamp
    }
  end

  defp conflict_attrs(%ProviderStatus{} = event) do
    attrs = %{
      provider_status: event.status,
      provider_status_at: event.provider_timestamp,
      provider_error_message: "conflicting Meta delivery status evidence",
      failure_reason: "provider_status_conflict",
      fallback_channel: "manual_review"
    }

    if is_nil(event.provider_error_code) do
      attrs
    else
      Map.put(attrs, :provider_error_code, event.provider_error_code)
    end
  end

  defp current_provider_status(%{provider_status: status}) when is_binary(status),
    do: status

  defp current_provider_status(%{status: status}) when status in ["sent", "delivered", "read"],
    do: status

  defp current_provider_status(_attempt), do: nil

  defp later_or_equal?(_timestamp, nil), do: true

  defp later_or_equal?(timestamp, current) do
    compare_timestamps(timestamp, current) in [:gt, :eq]
  end

  defp compare_timestamps(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right)

  defp compare_timestamps(%NaiveDateTime{} = left, %NaiveDateTime{} = right),
    do: NaiveDateTime.compare(left, right)

  defp compare_timestamps(%DateTime{} = left, %NaiveDateTime{} = right),
    do: DateTime.compare(left, DateTime.from_naive!(right, "Etc/UTC"))

  defp compare_timestamps(%NaiveDateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(DateTime.from_naive!(left, "Etc/UTC"), right)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp system_actor, do: %{actor_type: :system, actor_id: "whatsapp-delivery-status"}
end
