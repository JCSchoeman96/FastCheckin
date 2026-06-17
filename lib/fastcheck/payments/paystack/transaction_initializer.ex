defmodule FastCheck.Payments.Paystack.TransactionInitializer do
  @moduledoc """
  Provider-boundary API for Paystack transaction initialization.
  """

  alias FastCheck.Payments.Paystack.Client
  alias FastCheck.Payments.Paystack.Config
  alias FastCheck.Payments.Paystack.Error
  alias FastCheck.Payments.Paystack.InitializeResult
  alias FastCheck.Payments.Paystack.ResponseSanitizer

  @spec initialize(map(), keyword()) :: {:ok, InitializeResult.t()} | {:error, Error.t()}
  def initialize(params, opts \\ [])

  def initialize(params, opts) when is_map(params) do
    with {:ok, config} <- Config.validate_for_call(),
         {:ok, reference} <- Config.normalize_reference(Map.get(params, :reference) || Map.get(params, "reference")),
         {:ok, payload} <- build_payload(params, config, reference) do
      case Client.post("/transaction/initialize", payload, opts) do
        {:ok, response} -> {:ok, normalize_initialize_response(response)}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  def initialize(_params, _opts) do
    {:error, Error.new(%{type: :invalid_request, message: "initialize params must be a map"})}
  end

  defp build_payload(params, config, reference) do
    amount = fetch(params, :amount_cents)
    currency = fetch(params, :currency) || "ZAR"
    email = fetch(params, :email)
    metadata = fetch(params, :metadata) || %{}

    with :ok <- require_positive_integer(amount, :amount_cents),
         :ok <- require_non_empty(email, :email),
         :ok <- require_non_empty(currency, :currency),
         :ok <- require_map(metadata, :metadata) do
      callback_url = fetch(params, :callback_url) || config.callback_url

      payload =
        %{
          amount: amount,
          currency: currency,
          email: email,
          reference: reference,
          callback_url: callback_url,
          metadata: metadata
        }
        |> maybe_add_channels(config.allowed_channels)
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      {:ok, payload}
    end
  end

  defp maybe_add_channels(payload, []), do: payload
  defp maybe_add_channels(payload, channels), do: Map.put(payload, :channels, channels)

  defp normalize_initialize_response(response) do
    data = response["data"] || %{}

    %InitializeResult{
      provider_reference: data["reference"],
      authorization_url: data["authorization_url"],
      access_code: data["access_code"],
      status: response["status"],
      message: response["message"],
      safe_data: ResponseSanitizer.sanitize(data)
    }
  end

  defp require_positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp require_positive_integer(_value, field) do
    {:error,
     Error.new(%{
       type: :invalid_request,
       message: "#{field} must be a positive integer",
       safe_metadata: %{provider: :paystack, field: field}
     })}
  end

  defp require_non_empty(value, _field) when is_binary(value) and value != "", do: :ok

  defp require_non_empty(_value, field) do
    {:error,
     Error.new(%{
       type: :invalid_request,
       message: "#{field} is required",
       safe_metadata: %{provider: :paystack, field: field}
     })}
  end

  defp require_map(value, _field) when is_map(value), do: :ok

  defp require_map(_value, field) do
    {:error,
     Error.new(%{
       type: :invalid_request,
       message: "#{field} must be a map",
       safe_metadata: %{provider: :paystack, field: field}
     })}
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
