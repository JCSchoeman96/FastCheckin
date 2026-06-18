defmodule FastCheck.Tickets.TokenHash do
  @moduledoc """
  Purpose-bound HMAC hashing for Sales ticket QR and delivery bearer tokens.

  VS-08 stores only hashes at rest. Plaintext tokens are hashed with a dedicated
  pepper and a purpose prefix so delivery and QR tokens cannot cross-validate.
  """

  @purposes [:delivery, :qr]

  @doc """
  Returns the HMAC-SHA256 hex digest for `plaintext` under `purpose`.

  Supported purposes: `:delivery`, `:qr`.
  """
  @spec hash(String.t(), :delivery | :qr) :: String.t()
  def hash(plaintext, purpose) when is_binary(plaintext) and purpose in @purposes do
    :crypto.mac(:hmac, :sha256, pepper(), purpose_input(purpose, plaintext))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Constant-time comparison of `plaintext` against `stored_hash` for `purpose`.
  """
  @spec verify(String.t(), String.t(), :delivery | :qr) :: boolean()
  def verify(plaintext, stored_hash, purpose)
      when is_binary(plaintext) and is_binary(stored_hash) and purpose in @purposes do
    expected = hash(plaintext, purpose)

    byte_size(expected) == byte_size(stored_hash) and
      Plug.Crypto.secure_compare(expected, stored_hash)
  end

  @doc """
  Returns the configured ticket token pepper.

  Production requires `TICKET_TOKEN_PEPPER` (see `config/runtime.exs`).
  """
  @spec pepper() :: String.t()
  def pepper do
    Application.fetch_env!(:fastcheck, :ticket_token_pepper)
  end

  defp purpose_input(:delivery, plaintext), do: "delivery:" <> plaintext
  defp purpose_input(:qr, plaintext), do: "qr:" <> plaintext
end
