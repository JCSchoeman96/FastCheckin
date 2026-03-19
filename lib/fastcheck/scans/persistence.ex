defmodule FastCheck.Scans.Persistence do
  @moduledoc """
  Persists durable scan outcomes and projects accepted entries into the legacy
  attendee audit tables.
  """

  import Ecto.Query, only: [from: 2]

  alias FastCheck.Attendees.{Attendee, CheckIn, CheckInSession}
  alias FastCheck.Repo
  alias FastCheck.Scans.ScanAttempt

  @spec persist_batch([map()]) :: :ok | {:error, term()}
  def persist_batch(results) when is_list(results) do
    Enum.reduce_while(results, :ok, fn result, :ok ->
      case persist_result(result) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def persist_batch(_results), do: {:error, :invalid_batch}

  defp persist_result(result) when is_map(result) do
    attrs = scan_attempt_attrs(result)

    Repo.transaction(fn ->
      case %ScanAttempt{} |> ScanAttempt.changeset(attrs) |> Repo.insert() do
        {:ok, _scan_attempt} ->
          project_legacy_state(attrs)

        {:error, changeset} ->
          if unique_conflict?(changeset) do
            :ok
          else
            Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_legacy_state(%{status: "success", attendee_id: attendee_id} = attrs)
       when is_integer(attendee_id) do
    attendee = Repo.get!(Attendee, attendee_id)

    attendee_attrs = %{
      checked_in_at: parse_datetime(attrs.metadata["checked_in_at"]) || attrs.processed_at,
      last_checked_in_at: attrs.processed_at,
      checkins_remaining: attrs.metadata["remaining_after"]
    }

    with {:ok, updated_attendee} <-
           attendee |> Attendee.changeset(attendee_attrs) |> Repo.update(),
         {:ok, _check_in} <- insert_check_in(updated_attendee, attrs, "success"),
         {:ok, _session} <- upsert_active_session(updated_attendee, attrs) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp project_legacy_state(%{attendee_id: attendee_id, reason_code: reason_code} = attrs)
       when is_integer(attendee_id) and reason_code in ["PAYMENT_INVALID", "DUPLICATE"] do
    attendee = Repo.get!(Attendee, attendee_id)

    case insert_check_in(attendee, attrs, audit_status(reason_code)) do
      {:ok, _check_in} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp project_legacy_state(_attrs), do: :ok

  defp insert_check_in(attendee, attrs, status) do
    %CheckIn{}
    |> CheckIn.changeset(%{
      attendee_id: attendee.id,
      event_id: attrs.event_id,
      ticket_code: attrs.ticket_code,
      entrance_name: attrs.entrance_name,
      operator_name: attrs.operator_name,
      status: status,
      checked_in_at: attrs.processed_at
    })
    |> Repo.insert()
  end

  defp upsert_active_session(attendee, attrs) do
    query =
      from session in CheckInSession,
        where: session.attendee_id == ^attendee.id and session.event_id == ^attrs.event_id,
        where: is_nil(session.exit_time),
        order_by: [desc: session.inserted_at],
        limit: 1

    case Repo.one(query) do
      nil ->
        %CheckInSession{}
        |> CheckInSession.changeset(%{
          attendee_id: attendee.id,
          event_id: attrs.event_id,
          entry_time: attrs.processed_at,
          entrance_name: attrs.entrance_name
        })
        |> Repo.insert()

      %CheckInSession{} = session ->
        session
        |> CheckInSession.changeset(%{
          entry_time: attrs.processed_at,
          entrance_name: attrs.entrance_name
        })
        |> Repo.update()
    end
  end

  defp scan_attempt_attrs(result) do
    %{
      event_id: fetch(result, :event_id),
      attendee_id: fetch(result, :attendee_id),
      idempotency_key: fetch(result, :idempotency_key),
      ticket_code: fetch(result, :ticket_code),
      direction: fetch(result, :direction),
      status: fetch(result, :status),
      reason_code: fetch(result, :reason_code),
      message: fetch(result, :message),
      entrance_name: fetch(result, :entrance_name),
      operator_name: fetch(result, :operator_name),
      scanned_at: parse_datetime(fetch(result, :scanned_at)),
      processed_at:
        parse_datetime(fetch(result, :processed_at)) ||
          DateTime.utc_now() |> DateTime.truncate(:second),
      hot_state_version: fetch(result, :hot_state_version),
      metadata: fetch(result, :metadata) || %{}
    }
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp unique_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_message, opts}} ->
      field == :idempotency_key and
        opts[:constraint] == :unique and
        opts[:constraint_name] == "scan_attempts_event_idempotency_key_idx"
    end)
  end

  defp audit_status("PAYMENT_INVALID"), do: "payment_invalid"
  defp audit_status("DUPLICATE"), do: "duplicate"

  defp fetch(result, key) when is_map(result) do
    Map.get(result, key) || Map.get(result, Atom.to_string(key))
  end
end
