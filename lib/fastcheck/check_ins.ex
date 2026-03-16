defmodule FastCheck.CheckIns do
  @moduledoc """
  Native scanner check-in boundary.
  """

  alias FastCheck.CheckIns.{CheckInService, PackageService}

  @spec submit_scan(map(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate submit_scan(attrs, auth_context), to: CheckInService

  @spec flush_scans([map()], map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate flush_scans(scans, auth_context), to: CheckInService

  @spec latest_package_metadata(integer()) :: map() | nil
  defdelegate latest_package_metadata(event_id), to: PackageService
end
