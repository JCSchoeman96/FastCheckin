defmodule FastCheck.Load.MobileIntegrationScenario do
  @moduledoc """
  Domain-safe scenario helpers for mobile integration harness runs.

  This module mutates attendee state through FastCheck context rules so harness
  scenarios match production-admissible transitions.
  """

  import Ecto.Query

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.AttendeeInvalidationEvent
  alias FastCheck.Attendees.ReasonCodes
  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  @ineligible_status "not_scannable"
  @change_type_ineligible "ineligible"
  @default_dump_invalidation_limit 5

  @type scenario_dump :: %{
          event_id: integer(),
          ticket_code: String.t(),
          attendee_id: integer(),
          scan_eligibility: String.t() | nil,
          payment_status: String.t() | nil,
          event_sync_version: non_neg_integer(),
          invalidations: [map()]
        }

  @spec revoke_ticket(integer(), String.t(), keyword()) ::
          {:ok, %{attendee: Attendee.t(), changed: boolean()}} | {:error, term()}
  def revoke_ticket(event_id, ticket_code, opts \\ [])

  def revoke_ticket(event_id, ticket_code, opts)
      when is_integer(event_id) and is_binary(ticket_code) do
    reason_code =
      opts
      |> Keyword.get(:reason_code)
      |> normalize_reason_code()

    source_sync_run_id = Keyword.get(opts, :source_sync_run_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      attendee = fetch_attendee_for_update!(event_id, ticket_code)

      if attendee.scan_eligibility == @ineligible_status do
        %{attendee: attendee, changed: false}
      else
        updated =
          attendee
          |> Attendee.changeset(%{
            scan_eligibility: @ineligible_status,
            ineligibility_reason: reason_code,
            ineligible_since: now
          })
          |> Repo.update!()

        %AttendeeInvalidationEvent{}
        |> AttendeeInvalidationEvent.changeset(%{
          event_id: updated.event_id,
          attendee_id: updated.id,
          ticket_code: updated.ticket_code,
          change_type: @change_type_ineligible,
          reason_code: reason_code,
          effective_at: now,
          source_sync_run_id: source_sync_run_id
        })
        |> Repo.insert!()

        Events.bump_event_sync_version!(event_id)

        %{attendee: updated, changed: true}
      end
    end)
    |> unwrap_transaction()
  end

  def revoke_ticket(_event_id, _ticket_code, _opts), do: {:error, :invalid_arguments}

  @spec set_ticket_payment_status(integer(), String.t(), String.t()) ::
          {:ok, %{attendee: Attendee.t(), changed: boolean()}} | {:error, term()}
  def set_ticket_payment_status(event_id, ticket_code, payment_status)
      when is_integer(event_id) and is_binary(ticket_code) and is_binary(payment_status) do
    normalized_payment_status = payment_status |> String.trim() |> String.downcase()

    if normalized_payment_status == "" do
      {:error, :invalid_payment_status}
    else
      Repo.transaction(fn ->
        attendee = fetch_attendee_for_update!(event_id, ticket_code)

        if attendee.payment_status == normalized_payment_status do
          %{attendee: attendee, changed: false}
        else
          updated =
            attendee
            |> Attendee.changeset(%{payment_status: normalized_payment_status})
            |> Repo.update!()

          Events.bump_event_sync_version!(event_id)
          %{attendee: updated, changed: true}
        end
      end)
      |> unwrap_transaction()
    end
  end

  def set_ticket_payment_status(_event_id, _ticket_code, _payment_status),
    do: {:error, :invalid_arguments}

  @spec dump_ticket_state(integer(), String.t(), keyword()) ::
          {:ok, scenario_dump()} | {:error, term()}
  def dump_ticket_state(event_id, ticket_code, opts \\ [])

  def dump_ticket_state(event_id, ticket_code, opts)
      when is_integer(event_id) and is_binary(ticket_code) do
    limit = Keyword.get(opts, :invalidation_limit, @default_dump_invalidation_limit)

    with %Attendee{} = attendee <- fetch_attendee(event_id, ticket_code),
         %Event{} = event <- Repo.get(Event, event_id) do
      invalidations =
        AttendeeInvalidationEvent
        |> where(
          [event_row],
          event_row.event_id == ^event_id and event_row.ticket_code == ^attendee.ticket_code
        )
        |> order_by([event_row], desc: event_row.id)
        |> limit(^limit)
        |> Repo.all()
        |> Enum.map(fn invalidation ->
          %{
            id: invalidation.id,
            change_type: invalidation.change_type,
            reason_code: invalidation.reason_code,
            effective_at: invalidation.effective_at
          }
        end)

      {:ok,
       %{
         event_id: event.id,
         ticket_code: attendee.ticket_code,
         attendee_id: attendee.id,
         scan_eligibility: attendee.scan_eligibility,
         payment_status: attendee.payment_status,
         event_sync_version: event.event_sync_version || 0,
         invalidations: invalidations
       }}
    else
      nil -> {:error, :not_found}
    end
  end

  def dump_ticket_state(_event_id, _ticket_code, _opts), do: {:error, :invalid_arguments}

  defp fetch_attendee(event_id, ticket_code) do
    normalized_code = normalize_ticket_code(ticket_code)

    case normalized_code do
      nil ->
        nil

      value ->
        Repo.one(
          from attendee in Attendee,
            where: attendee.event_id == ^event_id and attendee.ticket_code == ^value,
            limit: 1
        )
    end
  end

  defp fetch_attendee_for_update!(event_id, ticket_code) do
    normalized_code =
      ticket_code
      |> normalize_ticket_code()
      |> case do
        nil -> raise ArgumentError, "ticket_code is required"
        code -> code
      end

    Repo.one!(
      from attendee in Attendee,
        where: attendee.event_id == ^event_id and attendee.ticket_code == ^normalized_code,
        lock: "FOR UPDATE"
    )
  end

  defp normalize_ticket_code(code) when is_binary(code) do
    code
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_reason_code(reason_code) when is_binary(reason_code) do
    case String.trim(reason_code) do
      "" -> ReasonCodes.revoked()
      normalized -> normalized
    end
  end

  defp normalize_reason_code(_), do: ReasonCodes.revoked()

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
