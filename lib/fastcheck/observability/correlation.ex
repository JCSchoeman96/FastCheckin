defmodule FastCheck.Observability.Correlation do
  @moduledoc """
  Correlation and idempotency propagation helpers for FastCheck Sales.

  Controllers should prefer an existing `correlation_id`, then `request_id`.
  Workers should reuse correlation identifiers from job args or originating
  state.   Never use buyer phone or email as correlation or idempotency keys.
  """

  require Logger

  @bounded_operational_keys [
    :request_id,
    :correlation_id,
    :idempotency_key,
    :actor_type,
    :actor_id,
    :event_id,
    :order_id,
    :order_public_reference,
    :checkout_session_id,
    :payment_attempt_id,
    :payment_event_id,
    :ticket_issue_id,
    :delivery_attempt_id,
    :conversation_id,
    :provider,
    :provider_reference_redacted,
    :channel,
    :status,
    :reason_code,
    :source,
    :worker,
    :queue,
    :attempt,
    :duration_ms,
    :result,
    :error_code
  ]

  @doc """
  Returns an existing correlation id, falls back to `request_id`, or generates
  a new opaque id. Never derives ids from buyer phone or email.
  """
  @spec ensure_correlation_id(map()) :: String.t()
  def ensure_correlation_id(context) when is_map(context) do
    context
    |> Map.get(:correlation_id)
    |> case do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        case Map.get(context, :request_id) || Map.get(context, "request_id") do
          id when is_binary(id) and id != "" -> id
          _ -> generate_correlation_id()
        end
    end
  end

  @doc "Reads correlation-related keys from current Logger metadata."
  @spec from_logger_metadata() :: map()
  def from_logger_metadata do
    metadata = Logger.metadata()

    %{
      request_id: metadata[:request_id],
      correlation_id: metadata[:correlation_id]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Extracts bounded operational metadata from Oban job args for logging.

  Does not return full args; only approved safe keys with present values.
  """
  @spec for_oban_args(map()) :: map()
  def for_oban_args(args) when is_map(args) do
    Enum.reduce(@bounded_operational_keys, %{}, fn key, acc ->
      value = Map.get(args, key) || Map.get(args, Atom.to_string(key))

      if is_nil(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  @doc "Merges metadata maps without overwriting an existing correlation id."
  @spec merge_metadata(map(), map()) :: map()
  def merge_metadata(left, right) when is_map(left) and is_map(right) do
    merged = Map.merge(left, right)

    case Map.get(left, :correlation_id) || Map.get(left, "correlation_id") do
      id when is_binary(id) and id != "" ->
        Map.put(merged, :correlation_id, id)

      _ ->
        merged
    end
  end

  @doc """
  Builds bounded Logger metadata for operational tracing.

  `idempotency_key` is only included when explicitly passed in `attrs`.
  """
  @spec operational_metadata(map()) :: keyword()
  def operational_metadata(attrs) when is_map(attrs) do
    attrs
    |> Map.take(@bounded_operational_keys)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.new()
  end

  @spec generate_correlation_id() :: String.t()
  def generate_correlation_id do
    Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
