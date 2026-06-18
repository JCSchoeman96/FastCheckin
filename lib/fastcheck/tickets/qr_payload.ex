defmodule FastCheck.Tickets.QrPayload do
  @moduledoc """
  Builds and parses scanner QR payload strings for Sales tickets.

  Release scanner compatibility: the active Android and Phoenix scanner paths expect
  the decoded barcode value to equal `Attendee.ticket_code` (plain string, no prefix).
  Optional `FC1:` versioned payloads are supported for parsing only.
  """

  alias FastCheck.Tickets.TokenHash

  @version_prefix "FC1:"

  @doc """
  Returns the scanner-compatible QR payload for `ticket_code`.

  Current scanner hot paths use the plain ticket code without a version prefix.
  """
  @spec build_for_scanner(String.t()) :: String.t()
  def build_for_scanner(ticket_code) when is_binary(ticket_code) do
    ticket_code
  end

  @doc """
  Builds a versioned QR payload string, e.g. `FC1:<value>`.
  """
  @spec build_versioned(String.t(), String.t()) :: String.t()
  def build_versioned(version, value) when is_binary(version) and is_binary(value) do
    version <> ":" <> value
  end

  @doc """
  Parses a QR payload string.

  Returns `{:ok, %{version: nil | String.t(), value: String.t()}}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, atom()}
  def parse(payload) when is_binary(payload) do
    payload = String.trim(payload)

    cond do
      payload == "" ->
        {:error, :invalid_format}

      String.starts_with?(payload, @version_prefix) ->
        value = String.replace_prefix(payload, @version_prefix, "")

        if value == "" do
          {:error, :invalid_format}
        else
          {:ok, %{version: "FC1", value: value}}
        end

      true ->
        {:ok, %{version: nil, value: payload}}
    end
  end

  def parse(_), do: {:error, :invalid_format}

  @doc """
  Generates a random opaque QR token and its `:qr` purpose hash.

  Plaintext is returned once for callers to embed or render; only the hash is persisted later.
  """
  @spec generate_qr_token() :: %{token: String.t(), hash: String.t()}
  def generate_qr_token do
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    %{token: token, hash: TokenHash.hash(token, :qr)}
  end

  @doc """
  Hashes `token` for QR lookup using the `:qr` purpose.
  """
  @spec hash_qr_token(String.t()) :: String.t()
  def hash_qr_token(token) when is_binary(token) do
    TokenHash.hash(token, :qr)
  end
end
