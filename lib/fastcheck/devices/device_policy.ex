defmodule FastCheck.Devices.DevicePolicy do
  @moduledoc """
  Event-scoped policy helpers for the native scanner scaffold.
  """

  import Ecto.Query, warn: false

  alias FastCheck.Repo
  alias FastCheck.Events.CheckInConfiguration
  alias FastCheck.Ticketing.Event

  @spec offline_capable?(Event.t()) :: boolean()
  def offline_capable?(%Event{scanner_policy_mode: "offline_capable"}), do: true
  def offline_capable?(_event), do: false

  @spec allow_reentry?(integer()) :: boolean()
  def allow_reentry?(event_id) when is_integer(event_id) do
    CheckInConfiguration
    |> where([config], config.event_id == ^event_id and config.allow_reentry == true)
    |> limit(1)
    |> Repo.exists?()
  end

  def allow_reentry?(_event_id), do: false
end
