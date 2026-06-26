defmodule FastCheck.Messaging.WhatsApp.WebhookVerifier do
  @moduledoc """
  Pure Meta WhatsApp webhook challenge and raw-body signature verification.
  """

  @max_challenge_bytes 256
  @signature_prefix "sha256="

  @spec verify_challenge(map(), String.t() | nil) ::
          {:ok, String.t()}
          | {:error,
             :invalid_mode | :invalid_verify_token | :missing_challenge | :invalid_challenge}
  def verify_challenge(params, configured_verify_token) when is_map(params) do
    mode = Map.get(params, "hub.mode")
    token = Map.get(params, "hub.verify_token")
    challenge = Map.get(params, "hub.challenge")

    cond do
      mode != "subscribe" ->
        {:error, :invalid_mode}

      not secure_equal?(token, configured_verify_token) ->
        {:error, :invalid_verify_token}

      not present?(challenge) ->
        {:error, :missing_challenge}

      not safe_challenge?(challenge) ->
        {:error, :invalid_challenge}

      true ->
        {:ok, challenge}
    end
  end

  @spec verify_signature(binary(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, :missing_signature | :invalid_signature | :missing_app_secret}
  def verify_signature(raw_body, signature_header, app_secret) when is_binary(raw_body) do
    cond do
      not present?(app_secret) ->
        {:error, :missing_app_secret}

      not present?(signature_header) ->
        {:error, :missing_signature}

      valid_signature?(raw_body, signature_header, app_secret) ->
        :ok

      true ->
        {:error, :invalid_signature}
    end
  end

  def verify_signature(_raw_body, _signature_header, _app_secret),
    do: {:error, :invalid_signature}

  defp valid_signature?(raw_body, signature_header, app_secret) do
    with @signature_prefix <> signature <- String.trim(signature_header),
         true <- hex_sha256?(signature) do
      expected =
        :crypto.mac(:hmac, :sha256, app_secret, raw_body)
        |> Base.encode16(case: :lower)

      Plug.Crypto.secure_compare(expected, String.downcase(signature))
    else
      _ -> false
    end
  end

  defp hex_sha256?(signature) do
    byte_size(signature) == 64 and String.match?(signature, ~r/\A[0-9a-fA-F]+\z/)
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp safe_challenge?(challenge) do
    byte_size(challenge) <= @max_challenge_bytes and
      String.match?(challenge, ~r/\A[0-9A-Za-z_.-]+\z/)
  end
end
