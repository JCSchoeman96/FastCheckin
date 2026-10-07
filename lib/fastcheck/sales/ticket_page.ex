defmodule FastCheck.Sales.TicketPage do
  @moduledoc """
  VS-11 customer secure ticket page domain boundary.

  Classifies delivery bearer tokens into customer-safe display states and returns
  only approved fields. Read-only: no issuance, delivery, payment, or scanner mutation.
  """

  alias FastCheck.Tickets.Artifact
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

  @spec from_artifact(Artifact.t()) :: result()
  def from_artifact(%Artifact{} = artifact) do
    %{
      state: artifact.state,
      event_name: artifact.event_name,
      attendee_name: artifact.attendee_name,
      ticket_type: artifact.ticket_type,
      qr_payload: artifact.scanner_payload,
      support_message: artifact.support_message
    }
  end

  @doc """
  Maps a session-read denial reason into the customer-safe page result shape.
  """
  @spec from_session_error(display_state()) :: result()
  def from_session_error(reason)
      when reason in [
             :not_found,
             :expired_link,
             :ticket_revoked,
             :ticket_not_ready,
             :ticket_not_scannable
           ] do
    %{
      state: reason,
      event_name: nil,
      attendee_name: nil,
      ticket_type: nil,
      qr_payload: nil,
      support_message: support_message_for(reason)
    }
  end

  @doc """
  Resolves a raw route delivery token into the legacy secure-ticket page result.

  Session-backed routes use `from_artifact/1` and `from_session_error/1` instead.
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

  defp support_message_for(:not_found),
    do: "This ticket link is not available. It may be invalid or expired."

  defp support_message_for(:expired_link),
    do: "This ticket link has expired. Please contact event support for help."

  defp support_message_for(:ticket_revoked),
    do: "This ticket has been cancelled. Please contact event support."

  defp support_message_for(:ticket_not_scannable),
    do: "This ticket is no longer valid for entry. Please contact event support."

  defp support_message_for(:ticket_not_ready),
    do: "Your ticket is not ready yet. Please try again later or contact support."
end
