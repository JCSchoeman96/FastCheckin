defmodule FastCheck.Scans.Validator do
  @moduledoc """
  Validation helpers for mobile scan uploads.
  """

  alias FastCheck.Scans.Ingest.ScanCommand

  @spec validate(integer(), map()) :: {:ok, ScanCommand.t()} | {:error, String.t()}
  def validate(event_id, scan) when is_integer(event_id) and is_map(scan) do
    with {:ok, key} <- extract_field(scan, "idempotency_key"),
         {:ok, ticket_code} <- extract_field(scan, "ticket_code"),
         {:ok, direction} <- extract_field(scan, "direction"),
         :ok <- validate_direction(direction),
         {:ok, scanned_at} <- parse_scanned_at(scan["scanned_at"]) do
      {:ok,
       %ScanCommand{
         event_id: event_id,
         idempotency_key: key,
         ticket_code: ticket_code,
         direction: direction,
         entrance_name: scan["entrance_name"] || "Mobile",
         operator_name: scan["operator_name"] || "Mobile Scanner",
         scanned_at: scanned_at
       }}
    end
  end

  def validate(_event_id, _scan), do: {:error, "Invalid scan format"}

  defp parse_scanned_at(nil), do: {:ok, nil}

  defp parse_scanned_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      _ -> {:error, "Invalid scanned_at timestamp"}
    end
  end

  defp parse_scanned_at(_value), do: {:error, "Invalid scanned_at timestamp"}

  defp extract_field(scan, field) do
    case Map.get(scan, field) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "Empty value for required field: #{field}"}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:error, "Missing required field: #{field}"}

      _ ->
        {:error, "Invalid value for required field: #{field}"}
    end
  end

  defp validate_direction("in"), do: :ok
  defp validate_direction("out"), do: :ok

  defp validate_direction(invalid),
    do: {:error, "Invalid direction: #{invalid}. Must be 'in' or 'out'"}
end
