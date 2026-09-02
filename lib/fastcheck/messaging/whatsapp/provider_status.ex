defmodule FastCheck.Messaging.WhatsApp.ProviderStatus do
  @moduledoc """
  Bounded, protected-value-free representation of Meta delivery status events.
  """

  alias FastCheck.Observability.Correlation

  @statuses ~w(sent delivered read failed deleted)
  @max_provider_message_id_length 256
  @max_error_code_length 64
  @max_correlation_id_length 128

  defstruct [
    :provider,
    :provider_message_id,
    :status,
    :provider_timestamp,
    :provider_error_code,
    :raw_payload_hash,
    :correlation_id
  ]

  @type t :: %__MODULE__{
          provider: String.t(),
          provider_message_id: String.t(),
          status: String.t(),
          provider_timestamp: DateTime.t(),
          provider_error_code: String.t() | nil,
          raw_payload_hash: String.t(),
          correlation_id: String.t()
        }

  @spec normalize(map(), keyword()) :: {:ok, [t()]} | {:error, :malformed_payload}
  def normalize(payload, opts \\ [])

  def normalize(payload, opts) when is_map(payload) do
    correlation_id =
      Correlation.ensure_correlation_id(%{
        correlation_id: safe_correlation_id(Keyword.get(opts, :correlation_id))
      })

    raw_payload_hash = Keyword.get(opts, :raw_payload_hash, "")

    statuses =
      payload
      |> status_values()
      |> Enum.flat_map(fn value ->
        value
        |> Map.get("statuses", [])
        |> List.wrap()
        |> Enum.flat_map(&normalize_status(&1, raw_payload_hash, correlation_id))
      end)

    {:ok, statuses}
  rescue
    _ -> {:error, :malformed_payload}
  end

  def normalize(_payload, _opts), do: {:error, :malformed_payload}

  @doc false
  def safe_summary(%__MODULE__{} = status) do
    %{
      provider: status.provider,
      provider_message_id_hash: hash_id(status.provider_message_id),
      status: status.status,
      provider_timestamp: DateTime.to_iso8601(status.provider_timestamp),
      provider_error_code: status.provider_error_code,
      raw_payload_hash: status.raw_payload_hash,
      correlation_id: status.correlation_id
    }
  end

  defp status_values(payload) do
    payload
    |> Map.get("entry", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"changes" => changes} when is_list(changes) -> changes
      _ -> []
    end)
    |> Enum.flat_map(fn
      %{"value" => value} when is_map(value) -> [value]
      _ -> []
    end)
    |> Enum.filter(&is_map/1)
  end

  defp normalize_status(
         %{"id" => provider_message_id, "status" => status, "timestamp" => timestamp} = event,
         raw_payload_hash,
         correlation_id
       )
       when is_binary(provider_message_id) and byte_size(provider_message_id) > 0 and
              byte_size(provider_message_id) <= @max_provider_message_id_length and
              status in @statuses do
    case parse_timestamp(timestamp) do
      {:ok, provider_timestamp} ->
        [
          %__MODULE__{
            provider: "meta",
            provider_message_id: provider_message_id,
            status: status,
            provider_timestamp: provider_timestamp,
            provider_error_code: provider_error_code(event),
            raw_payload_hash: raw_payload_hash,
            correlation_id: correlation_id
          }
        ]

      _ ->
        []
    end
  end

  defp normalize_status(_event, _raw_payload_hash, _correlation_id), do: []

  defp parse_timestamp(timestamp) when is_integer(timestamp) do
    from_unix_timestamp(timestamp)
  end

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case Integer.parse(String.trim(timestamp)) do
      {value, ""} -> from_unix_timestamp(value)
      _ -> :error
    end
  end

  defp parse_timestamp(_timestamp), do: :error

  defp from_unix_timestamp(timestamp) when is_integer(timestamp) and timestamp > 0 do
    {:ok, DateTime.from_unix!(timestamp) |> DateTime.truncate(:second)}
  rescue
    _ -> :error
  end

  defp from_unix_timestamp(_timestamp), do: :error

  defp provider_error_code(%{"errors" => [%{"code" => code} | _]}),
    do: safe_error_code(code)

  defp provider_error_code(_event), do: nil

  defp safe_error_code(code) when is_integer(code) do
    code
    |> Integer.to_string()
    |> safe_error_code()
  end

  defp safe_error_code(code) when is_binary(code) do
    code = String.trim(code)

    if byte_size(code) <= @max_error_code_length and Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, code),
      do: code,
      else: nil
  end

  defp safe_error_code(_code), do: nil

  defp safe_correlation_id(value) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) <= @max_correlation_id_length and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/, value),
       do: value,
       else: nil
  end

  defp safe_correlation_id(_value), do: nil

  defp hash_id(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end

defimpl Inspect, for: FastCheck.Messaging.WhatsApp.ProviderStatus do
  alias FastCheck.Messaging.WhatsApp.ProviderStatus

  def inspect(%ProviderStatus{} = status, opts) do
    status
    |> ProviderStatus.safe_summary()
    |> Inspect.Map.inspect(opts)
  end
end
