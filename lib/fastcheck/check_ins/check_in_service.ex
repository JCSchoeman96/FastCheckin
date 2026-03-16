defmodule FastCheck.CheckIns.CheckInService do
  @moduledoc """
  Minimal scan submission service for the native scanner scaffold.
  """

  alias FastCheck.Repo
  alias FastCheck.Ticketing
  alias FastCheck.CheckIns.{CheckInAttempt, DuplicateGuard, OfflineReconciliation}
  alias FastCheck.Devices.DevicePolicy
  alias FastCheck.Operations.ActivityFeed
  alias FastCheck.Ticketing.TicketNormalizer

  @accepted_decisions ["accepted_confirmed", "accepted_offline_pending"]

  @spec submit_scan(map(), map()) :: {:ok, map()} | {:error, term()}
  def submit_scan(attrs, %{session: session, device: device}) when is_map(attrs) do
    with {:ok, request_id} <- fetch_required_string(attrs, "request_id"),
         {:ok, ticket_code} <- fetch_required_string(attrs, "ticket_code"),
         {:ok, scanned_at_device} <- parse_datetime(attrs["scanned_at_device"]),
         {:ok, connectivity_mode} <- fetch_connectivity_mode(attrs["connectivity_mode"]),
         %FastCheck.Ticketing.Event{} = event <- Ticketing.get_event(session.event_id),
         %FastCheck.Ticketing.Ticket{} = ticket <-
           Ticketing.get_ticket_by_code(event.id, ticket_code) do
      decision = decision_for(event, ticket, connectivity_mode)
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      normalized_code = ticket.normalized_code || TicketNormalizer.normalize_code(ticket_code)
      gate = Ticketing.get_gate(event.id, session.gate_id)

      attrs =
        %{
          attendee_id: ticket.id,
          event_id: event.id,
          gate_id: gate_id(gate),
          device_id: device.id,
          device_session_id: session.id,
          request_id: request_id,
          ticket_code: normalized_code,
          checked_in_at: now,
          scanned_at_device: scanned_at_device,
          entrance_name: if(gate, do: gate.name, else: event.entrance_name || "Main"),
          operator_name: session.operator_name || "Scanner",
          status: if(decision in @accepted_decisions, do: "accepted", else: "rejected"),
          decision: decision,
          reconciliation_state: OfflineReconciliation.reconciliation_state(decision),
          connectivity_mode: connectivity_mode,
          app_version: attrs["app_version"],
          feedback_tone: feedback_tone(decision),
          feedback_color: feedback_color(decision),
          display_name: display_name(ticket),
          ticket_label: ticket.ticket_type
        }

      case %CheckInAttempt{} |> CheckInAttempt.changeset(attrs) |> Repo.insert() do
        {:ok, attempt} ->
          if decision in @accepted_decisions do
            _ = DuplicateGuard.mark_admitted(event.id, normalized_code)
          end

          ActivityFeed.broadcast_scan_summary(event.id, gate_id(gate), %{
            decision: decision,
            request_id: request_id,
            ticket_code: normalized_code
          })

          {:ok, response_for(attempt)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil ->
        reject_missing_ticket(attrs)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def submit_scan(_attrs, _auth_context),
    do: {:error, {"UNAUTHORIZED", "Valid device session required"}}

  @spec flush_scans([map()], map()) :: {:ok, [map()]} | {:error, term()}
  def flush_scans(scans, auth_context) when is_list(scans) do
    {:ok,
     Enum.map(scans, fn scan ->
       case submit_scan(scan, auth_context) do
         {:ok, result} ->
           result

         {:error, {code, message}} ->
           %{status: "error", decision: code, message: message}

         {:error, message} when is_binary(message) ->
           %{status: "error", decision: "INVALID", message: message}

         {:error, _reason} ->
           %{status: "error", decision: "INTERNAL_ERROR", message: "Unable to process scan"}
       end
     end)}
  end

  def flush_scans(_scans, _auth_context), do: {:error, {"INVALID", "scans must be an array"}}

  defp decision_for(event, ticket, connectivity_mode) do
    normalized_code =
      ticket.normalized_code || TicketNormalizer.normalize_code(ticket.ticket_code)

    cond do
      ticket.payment_status in ["voided", "refunded"] ->
        "rejected_voided"

      DuplicateGuard.admitted?(event.id, normalized_code) and
          not DevicePolicy.allow_reentry?(event.id) ->
        "rejected_duplicate"

      connectivity_mode == "offline" and DevicePolicy.offline_capable?(event) ->
        "accepted_offline_pending"

      connectivity_mode == "offline" ->
        "rejected_conflict"

      true ->
        "accepted_confirmed"
    end
  end

  defp response_for(attempt) do
    %{
      status: attempt.status,
      decision: attempt.decision,
      display_name: attempt.display_name,
      ticket_label: attempt.ticket_label,
      feedback_tone: attempt.feedback_tone,
      feedback_color: attempt.feedback_color,
      server_time: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      reconciliation_state: attempt.reconciliation_state
    }
  end

  defp reject_missing_ticket(attrs) do
    message = "Ticket not found"

    {:ok,
     %{
       status: "rejected",
       decision: "rejected_invalid",
       display_name: nil,
       ticket_label: nil,
       feedback_tone: "error",
       feedback_color: "red",
       server_time: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
       reconciliation_state: "none",
       request_id: attrs["request_id"],
       message: message
     }}
  end

  defp fetch_required_string(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {"INVALID", "#{key} is required"}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {"INVALID", "#{key} is required"}}
    end
  end

  defp fetch_connectivity_mode(value) when value in ["online", "offline"], do: {:ok, value}

  defp fetch_connectivity_mode(_value),
    do: {:error, {"INVALID", "connectivity_mode must be online or offline"}}

  defp parse_datetime(nil), do: {:ok, DateTime.utc_now() |> DateTime.truncate(:second)}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      _ -> {:error, {"INVALID", "scanned_at_device must be ISO8601"}}
    end
  end

  defp parse_datetime(_value), do: {:error, {"INVALID", "scanned_at_device must be ISO8601"}}

  defp feedback_tone(decision) when decision in @accepted_decisions, do: "success"
  defp feedback_tone("rejected_duplicate"), do: "warning"
  defp feedback_tone(_decision), do: "error"

  defp feedback_color(decision) when decision in @accepted_decisions, do: "green"
  defp feedback_color("rejected_duplicate"), do: "amber"
  defp feedback_color(_decision), do: "red"

  defp display_name(ticket) do
    [ticket.first_name, ticket.last_name]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp gate_id(nil), do: nil
  defp gate_id(gate), do: gate.id
end
