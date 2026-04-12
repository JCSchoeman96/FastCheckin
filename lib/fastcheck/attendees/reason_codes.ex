defmodule FastCheck.Attendees.ReasonCodes do
  @moduledoc """
  Stable reason codes for ineligible / invalidated attendees (FastCheck domain).

  Used for audit, support, and API contracts — avoid scattering magic strings.
  """

  @source_missing_from_authoritative_sync "source_missing_from_authoritative_sync"

  def source_missing_from_authoritative_sync, do: @source_missing_from_authoritative_sync
end
