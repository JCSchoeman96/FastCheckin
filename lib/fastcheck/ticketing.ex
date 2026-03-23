defmodule FastCheck.Ticketing do
  @moduledoc """
  Native scanner-facing ticketing boundary.

  During the scaffold phase this context resolves events and tickets through the
  existing FastCheck data model while exposing the target domain contract.
  """

  import Ecto.Query, warn: false

  alias FastCheck.Events
  alias FastCheck.Repo
  alias FastCheck.Ticketing.{Event, Gate, Ticket, TicketNormalizer}

  @spec get_event(integer()) :: Event.t() | nil
  def get_event(event_id) when is_integer(event_id), do: Repo.get(Event, event_id)
  def get_event(_event_id), do: nil

  @spec get_event_by_scanner_code(String.t()) :: Event.t() | nil
  def get_event_by_scanner_code(scanner_code) when is_binary(scanner_code) do
    Events.get_event_by_scanner_login_code(scanner_code)
  end

  def get_event_by_scanner_code(_scanner_code), do: nil

  @spec list_gates(integer()) :: [Gate.t()]
  def list_gates(event_id) when is_integer(event_id) do
    Gate
    |> where([gate], gate.event_id == ^event_id)
    |> order_by([gate], asc: gate.name)
    |> Repo.all()
  end

  def list_gates(_event_id), do: []

  @spec get_gate(integer(), integer() | nil) :: Gate.t() | nil
  def get_gate(_event_id, nil), do: nil

  def get_gate(event_id, gate_id) when is_integer(event_id) and is_integer(gate_id) do
    Gate
    |> where([gate], gate.id == ^gate_id and gate.event_id == ^event_id)
    |> Repo.one()
  end

  def get_gate(_event_id, _gate_id), do: nil

  @spec get_ticket_by_code(integer(), String.t()) :: Ticket.t() | nil
  def get_ticket_by_code(event_id, ticket_code)
      when is_integer(event_id) and is_binary(ticket_code) do
    normalized_code = TicketNormalizer.normalize_code(ticket_code)

    Ticket
    |> where(
      [ticket],
      ticket.event_id == ^event_id and ticket.normalized_code == ^normalized_code
    )
    |> limit(1)
    |> Repo.one()
  end

  def get_ticket_by_code(_event_id, _ticket_code), do: nil
end
