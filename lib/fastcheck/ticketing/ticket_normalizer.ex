defmodule FastCheck.Ticketing.TicketNormalizer do
  @moduledoc """
  Normalizes ticket codes into the stable representation used across the
  native scanner API, Redis dedupe keys, and database indexes.
  """

  @spec normalize_code(String.t() | nil) :: String.t() | nil
  def normalize_code(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.upcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_code(_value), do: nil
end
