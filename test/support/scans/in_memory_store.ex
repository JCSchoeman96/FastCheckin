defmodule FastCheck.TestSupport.Scans.InMemoryStore do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Scans.Ingest.ScanCommand
  alias FastCheck.Scans.Result

  @table :fastcheck_test_scan_store

  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  def process_scan(%ScanCommand{} = command, namespace) do
    ensure_table()
    state_key = {namespace, command.event_id, :state}
    idem_key = {namespace, command.event_id, :idempotency, command.idempotency_key}

    case :ets.lookup(@table, idem_key) do
      [{^idem_key, :final_acknowledged, result}] ->
        {:ok, %{result | delivery_state: :final_acknowledged}}

      [{^idem_key, :pending_durability, result}] ->
        {:ok, %{result | delivery_state: :pending_durability}}

      [] ->
        result = fresh_result(command, state_key)
        :ets.insert(@table, {idem_key, :pending_durability, result})
        {:ok, result}
    end
  end

  def promote_results(results, namespace) do
    ensure_table()

    Enum.each(results, fn %Result{} = result ->
      idem_key = {namespace, result.event_id, :idempotency, result.idempotency_key}

      :ets.insert(
        @table,
        {idem_key, :final_acknowledged, %{result | delivery_state: :final_acknowledged}}
      )
    end)

    :ok
  end

  def idempotency_entry(namespace, event_id, idempotency_key) do
    ensure_table()
    idem_key = {namespace, event_id, :idempotency, idempotency_key}

    case :ets.lookup(@table, idem_key) do
      [{^idem_key, stage, result}] -> %{stage: stage, result: result}
      [] -> nil
    end
  end

  defp fresh_result(%ScanCommand{} = command, state_key) do
    processed_at = DateTime.utc_now() |> DateTime.truncate(:second)
    state = load_state(state_key, command.event_id)

    case Map.get(state, command.ticket_code) do
      nil ->
        base_result(
          command,
          processed_at,
          "error",
          "INVALID",
          "Ticket not found: Ticket not found",
          nil,
          %{}
        )

      attendee ->
        cond do
          command.direction != "in" ->
            base_result(
              command,
              processed_at,
              "error",
              "NOT_IMPLEMENTED",
              "Check-out functionality not yet available",
              attendee.id,
              %{}
            )

          not payment_valid?(attendee.payment_status) ->
            base_result(
              command,
              processed_at,
              "error",
              "PAYMENT_INVALID",
              "Payment invalid: Entry denied: order status '#{normalize_payment_status(attendee.payment_status)}' is not completed",
              attendee.id,
              %{}
            )

          attendee.checked_in_at && attendee.checkins_remaining <= 0 ->
            base_result(
              command,
              processed_at,
              "error",
              "DUPLICATE",
              "Already checked in: Already checked in at #{DateTime.to_iso8601(attendee.checked_in_at)}",
              attendee.id,
              %{}
            )

          true ->
            updated =
              attendee
              |> Map.put(:checkins_remaining, max(attendee.checkins_remaining - 1, 0))
              |> Map.put(:checked_in_at, processed_at)

            :ets.insert(@table, {state_key, Map.put(state, command.ticket_code, updated)})

            base_result(
              command,
              processed_at,
              "success",
              "SUCCESS",
              "Check-in successful",
              attendee.id,
              %{
                "remaining_after" => updated.checkins_remaining,
                "checked_in_at" => DateTime.to_iso8601(processed_at)
              }
            )
        end
    end
  end

  defp load_state(state_key, event_id) do
    case :ets.lookup(@table, state_key) do
      [{^state_key, state}] ->
        state

      [] ->
        state =
          Repo.all(
            from attendee in Attendee,
              where: attendee.event_id == ^event_id,
              select: %{
                id: attendee.id,
                ticket_code: attendee.ticket_code,
                payment_status: attendee.payment_status,
                checkins_remaining:
                  fragment(
                    "coalesce(?, ?, 1)",
                    attendee.checkins_remaining,
                    attendee.allowed_checkins
                  ),
                checked_in_at: attendee.checked_in_at
              }
          )
          |> Map.new(fn attendee -> {attendee.ticket_code, attendee} end)

        :ets.insert(@table, {state_key, state})
        state
    end
  end

  defp base_result(command, processed_at, status, reason_code, message, attendee_id, metadata) do
    %Result{
      event_id: command.event_id,
      attendee_id: attendee_id,
      idempotency_key: command.idempotency_key,
      ticket_code: command.ticket_code,
      direction: command.direction,
      status: status,
      reason_code: reason_code,
      message: message,
      entrance_name: command.entrance_name,
      operator_name: command.operator_name,
      scanned_at: command.scanned_at,
      processed_at: processed_at,
      delivery_state: :new_staged,
      hot_state_version: "test",
      metadata: metadata
    }
  end

  defp payment_valid?(status) do
    normalized = normalize_payment_status(status)

    normalized == "completed" or
      (normalized == "unknown" and
         Application.get_env(:fastcheck, :allow_unknown_payment_status, false))
  end

  defp normalize_payment_status(nil), do: "unknown"

  defp normalize_payment_status(status) when is_binary(status) do
    normalized =
      status
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("wc-", "")

    cond do
      normalized == "" -> "unknown"
      String.contains?(normalized, "completed") -> "completed"
      true -> normalized
    end
  end

  defp normalize_payment_status(_), do: "unknown"

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> :ok
    end
  end
end
