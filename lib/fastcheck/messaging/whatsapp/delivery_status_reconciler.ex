defmodule FastCheck.Messaging.WhatsApp.DeliveryStatusReconciler do
  @moduledoc """
  Correlates signed Meta delivery evidence to exactly one tracked attempt.

  The reconciler writes an immutable evidence row before applying the
  monotonic projection to `sales_delivery_attempts`. It never creates an
  attempt for an unknown WAMID and never calls payment, ticket, inventory, or
  scanner authority code.
  """

  import Ecto.Query, only: [from: 2]

  alias FastCheck.Messaging.WhatsApp.ProviderStatus
  alias FastCheck.Repo

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
      {:ok, result} -> result
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :reconciliation_failed}
    end
  end

  def reconcile(%ProviderStatus{}), do: {:ignored, :unsupported_provider}

  defp reconcile_in_transaction(%ProviderStatus{} = event) do
    attempts =
      from(d in "sales_delivery_attempts",
        where:
          d.provider == "meta" and d.channel == "whatsapp" and
            d.provider_message_id == ^event.provider_message_id,
        select: d,
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    case attempts do
      [] ->
        {:ignored, :unknown_wamid}

      [attempt] ->
        case insert_evidence(event, attempt.id) do
          :duplicate ->
            {:duplicate, event.status}

          :inserted ->
            apply_evidence(attempt, event)
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

  defp apply_evidence(attempt, %ProviderStatus{} = event) do
    transition = transition(attempt, event)
    timestamp_attrs = evidence_timestamps(attempt, event, transition)

    attrs =
      timestamp_attrs
      |> Map.merge(transition_attrs(transition, event))
      |> Map.put(:updated_at, utc_now())

    if attrs == %{updated_at: attrs.updated_at} do
      case transition do
        :ignore -> {:ignored, :observational_status}
        _ -> {:ignored, :out_of_order}
      end
    else
      {1, _} =
        Repo.update_all(from(d in "sales_delivery_attempts", where: d.id == ^attempt.id),
          set: attrs
        )

      case transition do
        {:conflict, :manual_review} -> {:conflict, :manual_review}
        {:update, status} -> {:updated, status}
        :ignore -> {:ignored, :observational_status}
        :noop -> {:ignored, :out_of_order}
      end
    end
  end

  defp transition(%{status: _current_status}, %ProviderStatus{status: "deleted"}), do: :ignore

  defp transition(%{status: current_status}, _event) when current_status in @terminal_statuses,
    do: :ignore

  defp transition(attempt, %ProviderStatus{status: incoming_status} = event)
       when incoming_status in ["sent", "delivered", "read"] do
    current_provider_status = current_provider_status(attempt)
    current_rank = Map.get(@success_rank, current_provider_status, 0)
    incoming_rank = Map.fetch!(@success_rank, incoming_status)

    cond do
      current_provider_status == "failed" ->
        if later_or_equal?(event.provider_timestamp, attempt.provider_status_at),
          do: {:conflict, :manual_review},
          else: :noop

      incoming_rank < current_rank ->
        :noop

      incoming_rank == current_rank ->
        :noop

      current_provider_status in [nil, "accepted"] or is_nil(attempt.provider_status_at) ->
        {:update, incoming_status}

      later_or_equal?(event.provider_timestamp, attempt.provider_status_at) ->
        {:update, incoming_status}

      true ->
        :noop
    end
  end

  defp transition(attempt, %ProviderStatus{status: "failed"} = event) do
    current_provider_status = current_provider_status(attempt)

    cond do
      current_provider_status in ["delivered", "read"] ->
        if later_or_equal?(event.provider_timestamp, attempt.provider_status_at),
          do: {:conflict, :manual_review},
          else: :noop

      current_provider_status == "failed" ->
        if later_than?(event.provider_timestamp, attempt.provider_status_at),
          do: {:update, "failed"},
          else: :noop

      current_provider_status in [nil, "accepted"] ->
        {:update, "failed"}

      is_nil(attempt.provider_status_at) or
          later_or_equal?(event.provider_timestamp, attempt.provider_status_at) ->
        {:update, "failed"}

      true ->
        :noop
    end
  end

  defp transition(_attempt, _event), do: :noop

  defp transition_attrs(:ignore, _event), do: %{}
  defp transition_attrs(:noop, _event), do: %{}

  defp transition_attrs({:update, status}, event) do
    %{
      status: status,
      provider_status: event.status,
      provider_status_at: event.provider_timestamp
    }
    |> maybe_failed_attrs(status, event)
  end

  defp transition_attrs({:conflict, :manual_review}, event) do
    %{
      status: "manual_review",
      provider_status: event.status,
      provider_status_at: event.provider_timestamp,
      failure_reason: "provider_status_conflict",
      fallback_channel: "manual_review",
      provider_error_message: "conflicting Meta delivery status evidence"
    }
    |> maybe_put_provider_error_code(event.provider_error_code)
  end

  defp maybe_failed_attrs(attrs, "failed", event) do
    attrs
    |> Map.put(:failure_reason, "provider_status_failed")
    |> maybe_put_provider_error_code(event.provider_error_code)
  end

  defp maybe_failed_attrs(attrs, _status, _event), do: attrs

  defp maybe_put_provider_error_code(attrs, nil), do: attrs
  defp maybe_put_provider_error_code(attrs, code), do: Map.put(attrs, :provider_error_code, code)

  defp evidence_timestamps(_attempt, _event, transition)
       when transition in [:ignore, :noop],
       do: %{}

  defp evidence_timestamps(
         attempt,
         %ProviderStatus{status: status, provider_timestamp: timestamp},
         _transition
       ) do
    case status do
      "sent" -> maybe_min_timestamp(:sent_at, attempt.sent_at, timestamp)
      "delivered" -> maybe_min_timestamp(:delivered_at, attempt.delivered_at, timestamp)
      "read" -> maybe_min_timestamp(:read_at, attempt.read_at, timestamp)
      "failed" -> maybe_min_timestamp(:failed_at, attempt.failed_at, timestamp)
      "deleted" -> %{}
    end
  end

  defp maybe_min_timestamp(_field, existing, _timestamp) when not is_nil(existing),
    do: %{}

  defp maybe_min_timestamp(field, nil, timestamp), do: Map.put(%{}, field, timestamp)

  defp current_provider_status(%{provider_status: status}) when is_binary(status), do: status

  defp current_provider_status(%{status: status}) when status in ["sent", "delivered", "read"],
    do: status

  defp current_provider_status(%{status: "failed"}), do: "failed"
  defp current_provider_status(_attempt), do: nil

  defp later_or_equal?(timestamp, nil) when is_struct(timestamp, DateTime), do: true

  defp later_or_equal?(timestamp, current) do
    DateTime.compare(timestamp, current) in [:gt, :eq]
  end

  defp later_than?(_timestamp, nil), do: true

  defp later_than?(timestamp, current), do: DateTime.compare(timestamp, current) == :gt

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
