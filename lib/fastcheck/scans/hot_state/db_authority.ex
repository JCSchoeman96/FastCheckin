# PostgreSQL-backed checks for mobile scan hot state. Redis snapshots can lag
# eligibility changes; this module lets the authoritative path reject tickets
# that are absent or marked not_scannable before evaluating Redis/Lua.
defmodule FastCheck.Scans.HotState.DbAuthority do
  @moduledoc false

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo

  @spec check(integer(), String.t()) ::
          :ok | {:reject, :not_found | {:not_scannable, integer()}}
  def check(event_id, ticket_code)
      when is_integer(event_id) and is_binary(ticket_code) do
    case Repo.get_by(Attendee, event_id: event_id, ticket_code: ticket_code) do
      nil ->
        {:reject, :not_found}

      %Attendee{scan_eligibility: "not_scannable", id: id} ->
        {:reject, {:not_scannable, id}}

      %Attendee{} ->
        :ok
    end
  end
end
