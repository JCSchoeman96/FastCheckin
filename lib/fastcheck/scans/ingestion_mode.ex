defmodule FastCheck.Scans.IngestionMode do
  @moduledoc false

  @type t :: :legacy | :shadow | :redis_authoritative

  @spec resolve(atom() | String.t() | nil) :: t()
  def resolve(:redis_authoritative), do: :redis_authoritative
  def resolve(:shadow), do: :shadow
  def resolve(:legacy), do: :legacy

  def resolve(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "redis_authoritative" -> :redis_authoritative
      "shadow" -> :shadow
      "legacy" -> :legacy
      _ -> :legacy
    end
  end

  def resolve(_value), do: :legacy
end
