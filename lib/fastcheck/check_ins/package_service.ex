defmodule FastCheck.CheckIns.PackageService do
  @moduledoc """
  Offline package metadata access for the native scanner scaffold.
  """

  import Ecto.Query, warn: false

  alias FastCheck.Repo
  alias FastCheck.CheckIns.OfflineEventPackage

  @spec latest_package_metadata(integer()) :: map() | nil
  def latest_package_metadata(event_id) when is_integer(event_id) do
    OfflineEventPackage
    |> where([package], package.event_id == ^event_id)
    |> order_by([package], desc: package.version)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      package -> %{version: package.version, status: package.status, checksum: package.checksum}
    end
  end

  def latest_package_metadata(_event_id), do: nil
end
