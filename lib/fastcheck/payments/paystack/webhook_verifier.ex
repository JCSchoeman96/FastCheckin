defmodule FastCheck.Payments.Paystack.WebhookVerifier do
  @moduledoc """
  Pure raw-body HMAC signature verifier for Paystack webhooks.
  """

  alias FastCheck.Payments.Paystack.Error

  @header_key "x-paystack-signature"

  @spec valid_signature?(binary(), String.t() | nil, String.t()) :: boolean()
  def valid_signature?(raw_body, signature_header, secret_key)
      when is_binary(raw_body) and is_binary(secret_key) do
    with {:ok, signature} <- normalize_signature(signature_header),
         true <- byte_size(secret_key) > 0 do
      expected =
        :sha512
        |> :crypto.mac(:hmac, secret_key, raw_body)
        |> Base.encode16(case: :lower)

      Plug.Crypto.secure_compare(expected, signature)
    else
      _ -> false
    end
  end

  def valid_signature?(_raw_body, _signature_header, _secret_key), do: false

  @spec verify(binary(), map() | String.t() | nil, keyword()) ::
          {:ok, :valid} | {:error, Error.t()}
  def verify(raw_body, headers_or_signature, opts \\ [])

  def verify(raw_body, headers, opts) when is_map(headers) do
    signature = Map.get(headers, @header_key) || Map.get(headers, String.downcase(@header_key))
    verify(raw_body, signature, opts)
  end

  def verify(raw_body, signature_header, opts) when is_binary(raw_body) do
    secret_key = Keyword.get(opts, :secret_key)

    cond do
      not is_binary(secret_key) or secret_key == "" ->
        {:error,
         %Error{
           type: :missing_config,
           message: "missing paystack webhook secret",
           safe_metadata: %{provider: :paystack}
         }}

      valid_signature?(raw_body, signature_header, secret_key) ->
        {:ok, :valid}

      true ->
        {:error,
         %Error{
           type: :invalid_signature,
           message: "invalid paystack webhook signature",
           safe_metadata: %{provider: :paystack}
         }}
    end
  end

  def verify(_raw_body, _headers_or_signature, _opts) do
    {:error,
     %Error{
       type: :invalid_request,
       message: "raw webhook body must be a binary",
       safe_metadata: %{provider: :paystack}
     }}
  end

  defp normalize_signature(signature) when is_binary(signature) do
    cleaned = signature |> String.trim() |> String.downcase()
    if cleaned == "", do: {:error, :missing_signature}, else: {:ok, cleaned}
  end

  defp normalize_signature(_), do: {:error, :missing_signature}
end
