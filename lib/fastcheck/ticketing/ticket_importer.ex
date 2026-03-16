defmodule FastCheck.Ticketing.TicketImporter do
  @moduledoc """
  Placeholder import boundary for moving Tickera sync responsibilities into the
  Ticketing domain.
  """

  @spec import_event(integer()) :: {:ok, %{event_id: integer(), status: :scaffolded}}
  def import_event(event_id) when is_integer(event_id) do
    {:ok, %{event_id: event_id, status: :scaffolded}}
  end
end
