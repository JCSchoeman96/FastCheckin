defmodule FastCheck.Attendees do
  @moduledoc """
  Context responsible for attendee persistence, ticket scanning, and reporting.
  """

  import Ecto.Query, warn: false
  require Logger

  alias FastCheck.{Repo, Attendees.Attendee, Attendees.CheckIn, TickeraClient}

  @doc """
  Bulk inserts attendees for the provided event.

  Returns `{:ok, count}` where `count` is the number of new attendees stored.
  """
  @spec create_bulk(integer(), list()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def create_bulk(event_id, attendees_data) when is_integer(event_id) and is_list(attendees_data) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      attendees_data
      |> Enum.map(fn ticket ->
        parsed = TickeraClient.parse_attendee(ticket)

        allowed =
          parsed
          |> Map.get(:allowed_checkins)
          |> normalize_allowed_checkins()

        parsed
        |> Map.put(:event_id, event_id)
        |> Map.put_new(:checkins_remaining, allowed)
        |> Map.put(:allowed_checkins, allowed)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)
      |> Enum.reject(fn row -> is_nil(Map.get(row, :ticket_code)) end)

    try do
      case entries do
        [] ->
          Logger.info("No attendees to insert for event #{event_id}")
          {:ok, 0}

        _ ->
          {count, _} = Repo.insert_all(Attendee, entries, on_conflict: :nothing)
          Logger.info("Inserted #{count} attendees for event #{event_id}")
          {:ok, count}
      end
    rescue
      exception ->
        Logger.error("Bulk attendee insert failed for event #{event_id}: #{Exception.message(exception)}")
        {:error, "Failed to store attendees"}
    end
  end

  def create_bulk(_event_id, _data), do: {:error, "Invalid attendee data"}

  @doc """
  Processes a check-in attempt for a ticket code.

  Returns `{:ok, attendee, "SUCCESS"}` when the scan is valid, otherwise
  `{:error, code, message}` describing the failure.
  """
  @spec check_in(integer(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def check_in(event_id, ticket_code, entrance_name \\ "Main", operator_name \\ nil)
      when is_integer(event_id) and is_binary(ticket_code) do
    query =
      from(a in Attendee,
        where: a.event_id == ^event_id and a.ticket_code == ^ticket_code,
        lock: "FOR UPDATE"
      )

    try do
      Repo.transaction(fn ->
        case Repo.one(query) do
          nil ->
            Logger.warn("Invalid ticket #{ticket_code} for event #{event_id}")
            record_check_in(%{ticket_code: ticket_code}, event_id, "invalid", entrance_name, operator_name)
            {:error, "INVALID", "Ticket not found"}

          %Attendee{} = attendee ->
            remaining = attendee.checkins_remaining || attendee.allowed_checkins || 0

            cond do
              attendee.checked_in_at && remaining <= 0 ->
                Logger.warn("Duplicate ticket #{ticket_code} for event #{event_id}")
                record_check_in(attendee, event_id, "duplicate", entrance_name, operator_name)
                {:error, "DUPLICATE", "Already checked in at #{format_datetime(attendee.checked_in_at)}"}

              true ->
                now = DateTime.utc_now() |> DateTime.truncate(:second)
                new_remaining = max(remaining - 1, 0)

                attrs = %{
                  checked_in_at: now,
                  last_checked_in_at: now,
                  checkins_remaining: new_remaining
                }

                case Attendee.changeset(attendee, attrs) |> Repo.update() do
                  {:ok, updated} ->
                    record_check_in(updated, event_id, "success", entrance_name, operator_name)
                    Logger.info("Ticket #{ticket_code} checked in for event #{event_id}")
                    {:ok, updated, "SUCCESS"}

                  {:error, changeset} ->
                    Logger.error("Failed to update attendee #{attendee.id}: #{inspect(changeset.errors)}")
                    Repo.rollback({:changeset, "Failed to update attendee"})
                end
            end
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, {:changeset, message}} -> {:error, "ERROR", message}
        {:error, reason} ->
          Logger.error("Check-in transaction failed for #{ticket_code}: #{inspect(reason)}")
          {:error, "ERROR", "Unable to process check-in"}
      end
    rescue
      exception ->
        Logger.error("Check-in crashed for #{ticket_code}: #{Exception.message(exception)}")
        {:error, "ERROR", "Unexpected error"}
    end
  end

  def check_in(_, _, _, _), do: {:error, "INVALID", "Ticket not found"}

  @doc """
  Fetches a single attendee by ticket code within an event.
  """
  @spec get_attendee(integer(), String.t()) :: Attendee.t() | nil
  def get_attendee(event_id, ticket_code) when is_integer(event_id) and is_binary(ticket_code) do
    Repo.get_by(Attendee, event_id: event_id, ticket_code: ticket_code)
  end

  def get_attendee(_, _), do: nil

  @doc """
  Lists all attendees for the given event ordered by most recent check-in.
  """
  @spec list_event_attendees(integer()) :: [Attendee.t()]
  def list_event_attendees(event_id) when is_integer(event_id) do
    from(a in Attendee,
      where: a.event_id == ^event_id,
      order_by: [desc: a.checked_in_at]
    )
    |> Repo.all()
  end

  def list_event_attendees(_), do: []

  @doc """
  Computes aggregate statistics for an event's attendees.
  """
  @spec get_event_stats(integer()) :: %{total: integer(), checked_in: integer(), pending: integer(), percentage: float()}
  def get_event_stats(event_id) when is_integer(event_id) do
    try do
      total =
        from(a in Attendee,
          where: a.event_id == ^event_id,
          select: count(a.id)
        )
        |> Repo.one()
        |> Kernel.||(0)

      checked_in =
        from(a in Attendee,
          where: a.event_id == ^event_id and not is_nil(a.checked_in_at),
          select: count(a.id)
        )
        |> Repo.one()
        |> Kernel.||(0)

      pending = max(total - checked_in, 0)
      percentage = if total == 0, do: 0.0, else: Float.round(checked_in / total * 100, 2)

      %{total: total, checked_in: checked_in, pending: pending, percentage: percentage}
    rescue
      exception ->
        Logger.error("Failed to compute stats for event #{event_id}: #{Exception.message(exception)}")
        %{total: 0, checked_in: 0, pending: 0, percentage: 0.0}
    end
  end

  def get_event_stats(_), do: %{total: 0, checked_in: 0, pending: 0, percentage: 0.0}

  defp record_check_in(attendee, event_id, status, entrance_name, operator_name) do
    ticket_code = attendee && Map.get(attendee, :ticket_code)

    attrs = %{
      attendee_id: attendee && Map.get(attendee, :id),
      event_id: event_id,
      ticket_code: ticket_code,
      entrance_name: entrance_name,
      operator_name: operator_name,
      status: status,
      checked_in_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %CheckIn{}
    |> CheckIn.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, check_in} -> {:ok, check_in}
      {:error, changeset} ->
        Logger.error("Failed to record check-in for #{ticket_code || "unknown"}: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp normalize_allowed_checkins(value) when is_integer(value) and value >= 0, do: value
  defp normalize_allowed_checkins(_), do: 1

  defp format_datetime(nil), do: "unknown time"

  defp format_datetime(datetime) do
    datetime
    |> DateTime.to_string()
  rescue
    _ -> "unknown time"
  end
end
