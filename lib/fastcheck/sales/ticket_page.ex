defmodule FastCheck.Sales.TicketPage do
  @moduledoc """
  VS-11 customer secure ticket page domain boundary.

  Classifies delivery bearer tokens into customer-safe display states and returns
  only approved fields. Read-only: no issuance, delivery, payment, or scanner mutation.
  """

  alias FastCheck.Tickets.ArtifactResolver

  @type display_state ::
          :valid
          | :not_found
          | :expired_link
          | :ticket_revoked
          | :ticket_not_scannable
          | :ticket_not_ready

  @type result :: %{
          state: display_state(),
          event_name: String.t() | nil,
          attendee_name: String.t() | nil,
          ticket_type: String.t() | nil,
          qr_payload: String.t() | nil,
          support_message: String.t()
        }

  @doc """
  Resolves a raw route delivery token into the legacy secure-ticket page result.

  The public return shape is intentionally stable for the controller/template.
  """
  @spec resolve(term()) :: result()
  def resolve(raw_token) do
    case ArtifactResolver.resolve_from_delivery_token(raw_token) do
      {:ok, artifact} ->
        %{
          state: artifact.state,
          event_name: artifact.event_name,
          attendee_name: artifact.attendee_name,
          ticket_type: artifact.ticket_type,
          qr_payload: artifact.scanner_payload,
          support_message: artifact.support_message
        }

      {:error, error} ->
        %{
          state: error.state,
          event_name: nil,
          attendee_name: nil,
          ticket_type: nil,
          qr_payload: nil,
          support_message: error.support_message
        }
    end
  end
end
