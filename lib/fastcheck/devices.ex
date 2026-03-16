defmodule FastCheck.Devices do
  @moduledoc """
  Device and session boundary for the native scanner API.
  """

  import Ecto.Query, warn: false

  alias FastCheck.Repo
  alias FastCheck.Devices.{Device, DeviceSession, SessionService}

  @spec get_device(integer()) :: Device.t() | nil
  def get_device(device_id) when is_integer(device_id), do: Repo.get(Device, device_id)
  def get_device(_device_id), do: nil

  @spec get_session(integer()) :: DeviceSession.t() | nil
  def get_session(session_id) when is_integer(session_id), do: Repo.get(DeviceSession, session_id)
  def get_session(_session_id), do: nil

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  defdelegate create_session(attrs), to: SessionService

  @spec authenticate_bearer(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate authenticate_bearer(token), to: SessionService

  @spec revoke_session(DeviceSession.t()) :: {:ok, DeviceSession.t()} | {:error, term()}
  defdelegate revoke_session(session), to: SessionService
end
