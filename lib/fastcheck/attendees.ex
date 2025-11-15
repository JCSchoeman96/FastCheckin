defmodule FastCheck.Attendees do
  @moduledoc """
  Context module encapsulating persistence helpers for attendee records.

  Right now it exposes a bulk upsert API leveraged by the event sync pipeline
  so we can ingest thousands of attendees without issuing one query per row.
  """

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo

  @type attendee_payload :: map()

  @doc """
  Persists the provided attendees for the supplied `event_id`.

  The function performs an upsert on `event_id` + `ticket_code` so re-syncing an
  event updates existing rows rather than failing with uniqueness violations.
  """
  @spec create_bulk(pos_integer(), [attendee_payload()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def create_bulk(event_id, attendees)
      when is_integer(event_id) and event_id > 0 and is_list(attendees) do
    entries =
      attendees
      |> Enum.map(&normalize_attendee(event_id, &1))
      |> Enum.reject(&is_nil/1)

    if entries == [] do
      {:ok, 0}
    else
      Repo.transaction(fn ->
        {count, _} =
          Repo.insert_all(Attendee, entries,
            on_conflict: {:replace_all_except, [:id, :inserted_at]},
            conflict_target: [:event_id, :ticket_code]
          )

        count
      end)
      |> case do
        {:ok, count} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create_bulk(_event_id, _attendees), do: {:error, "Invalid attendee payload"}

  defp normalize_attendee(event_id, attrs) when is_map(attrs) do
    with ticket_code when is_binary(ticket_code) <- fetch(attrs, :ticket_code) do
      now = DateTime.utc_now()

      allowed_checkins = parse_integer(fetch(attrs, :allowed_checkins), 1)

      checkins_remaining =
        fetch(attrs, :checkins_remaining)
        |> parse_integer(allowed_checkins)

      %{
        event_id: event_id,
        ticket_code: ticket_code,
        first_name: fetch(attrs, :first_name),
        last_name: fetch(attrs, :last_name),
        email: fetch(attrs, :email),
        ticket_type: fetch(attrs, :ticket_type) || fetch(attrs, :ticket_type_name),
        allowed_checkins: allowed_checkins,
        checkins_remaining: checkins_remaining,
        payment_status: fetch(attrs, :payment_status) || fetch(attrs, :status),
        custom_fields: fetch(attrs, :custom_fields) |> ensure_map(),
        checked_in_at: fetch(attrs, :checked_in_at) |> parse_datetime(),
        last_checked_in_at: fetch(attrs, :last_checked_in_at) |> parse_datetime(),
        inserted_at: fetch(attrs, :inserted_at) |> parse_datetime() || now,
        updated_at: fetch(attrs, :updated_at) |> parse_datetime() || now
      }
    else
      _ ->
        nil
    end
  end

  defp normalize_attendee(_event_id, _attrs), do: nil

  defp fetch(attrs, key) when is_map(attrs) do
    atom_key = if is_atom(key), do: key, else: String.to_atom(to_string(key))
    string_key = to_string(key)

    Map.get(attrs, atom_key) || Map.get(attrs, string_key)
  rescue
    ArgumentError -> Map.get(attrs, string_key)
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}

  defp parse_integer(value, default) when is_integer(value), do: value

  defp parse_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_integer(_value, default), do: default

  defp parse_datetime(%DateTime{} = value), do: value
  defp parse_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp parse_datetime(_), do: nil
end
