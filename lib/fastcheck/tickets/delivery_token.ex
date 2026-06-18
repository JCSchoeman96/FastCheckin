defmodule FastCheck.Tickets.DeliveryToken do
  @moduledoc """
  Customer secure ticket-page bearer token primitives for Sales.

  VS-08 generates plaintext once plus a purpose-bound hash and expiry timestamp.
  Persistence, rotation, and page rendering belong to later slices.
  """

  alias FastCheck.Tickets.TokenHash

  @entropy_bytes 32
  @default_ttl_seconds 90 * 24 * 60 * 60

  @doc """
  Generates a delivery bearer token bundle.

  Returns `%{token: plaintext, hash: delivery_token_hash, expires_at: DateTime.t()}`.
  Plaintext must not be persisted; only `hash` and `expires_at` are stored later.
  """
  @spec generate(keyword()) :: %{token: String.t(), hash: String.t(), expires_at: DateTime.t()}
  def generate(opts \\ []) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(@entropy_bytes), padding: false)
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))
    ttl_seconds = Keyword.get(opts, :ttl_seconds, default_ttl_seconds())
    expires_at = DateTime.add(now, ttl_seconds, :second)

    %{
      token: token,
      hash: TokenHash.hash(token, :delivery),
      expires_at: expires_at
    }
  end

  @doc """
  Verifies `plaintext` against a stored delivery hash.
  """
  @spec verify_hash(String.t(), String.t()) :: boolean()
  def verify_hash(plaintext, stored_hash)
      when is_binary(plaintext) and is_binary(stored_hash) do
    TokenHash.verify(plaintext, stored_hash, :delivery)
  end

  @doc """
  Verifies a delivery token against ticket issue context.

  Returns `:ok` or `{:error, :invalid | :expired | :revoked}`.
  """
  @spec verify_context(String.t(), map()) :: :ok | {:error, atom()}
  def verify_context(plaintext, ticket_issue)
      when is_binary(plaintext) and is_map(ticket_issue) do
    hash =
      Map.get(ticket_issue, :delivery_token_hash) || Map.get(ticket_issue, "delivery_token_hash")

    expires_at =
      Map.get(ticket_issue, :delivery_token_expires_at) ||
        Map.get(ticket_issue, "delivery_token_expires_at")

    with false <- revoked?(ticket_issue),
         :ok <- verify_expiry(expires_at),
         true <- is_binary(hash) and verify_hash(plaintext, hash) do
      :ok
    else
      true -> {:error, :revoked}
      {:error, :expired} -> {:error, :expired}
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Returns whether ticket issue context represents a revoked ticket.
  """
  @spec revoked?(map()) :: boolean()
  def revoked?(ticket_issue) when is_map(ticket_issue) do
    status = Map.get(ticket_issue, :status) || Map.get(ticket_issue, "status")
    revoked_at = Map.get(ticket_issue, :revoked_at) || Map.get(ticket_issue, "revoked_at")

    status == "revoked" or not is_nil(revoked_at)
  end

  @doc """
  Returns a fresh token bundle for rotation.

  Persistence of the new hash belongs to later revocation/resend slices.
  """
  @spec rotate(keyword()) :: %{token: String.t(), hash: String.t(), expires_at: DateTime.t()}
  def rotate(opts \\ []), do: generate(opts)

  defp verify_expiry(nil), do: {:error, :expired}

  defp verify_expiry(%DateTime{} = expires_at) do
    if DateTime.compare(DateTime.utc_now(), expires_at) == :gt do
      {:error, :expired}
    else
      :ok
    end
  end

  defp default_ttl_seconds do
    Application.get_env(:fastcheck, :sales_delivery_token_ttl_seconds, @default_ttl_seconds)
  end
end
