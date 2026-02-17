defmodule FastCheck.Mobile.Token do
  @moduledoc """
  Centralized JWT token handling for mobile scanner authentication.

  This module provides a clean API for issuing and verifying JWT tokens
  that mobile scanner clients use to authenticate with the FastCheckin API.

  ## Token Claims

  Mobile tokens include the following claims:
  - `event_id` - The ID of the event this token grants access to
  - `role` - Always "scanner" for mobile scanner tokens
  - `exp` - Token expiration timestamp (Unix timestamp)
  - `iat` - Token issued at timestamp (Unix timestamp)

  ## Configuration

  The module reads configuration from the application environment:

      config :fastcheck, FastCheck.Mobile.Token,
        secret_key: "your-256-bit-secret",
        token_ttl_seconds: 86400,  # 24 hours
        issuer: "fastcheck",
        algorithm: "HS256"

  ## Error Handling

  Token verification can fail for several reasons:
  - `:expired` - Token has passed its expiration time
  - `:invalid_signature` - Token signature does not match (tampered or wrong key)
  - `:malformed` - Token structure is invalid or cannot be decoded
  - `:missing_claims` - Required claims (event_id, role) are missing
  - `:invalid_issuer` - Issuer claim is missing or does not match configuration

  ## Examples

      # Issue a token for event 123
      {:ok, token} = FastCheck.Mobile.Token.issue_scanner_token(123)

      # Verify a token and extract claims
      case FastCheck.Mobile.Token.verify_token(token) do
        {:ok, claims} ->
          event_id = claims["event_id"]
          role = claims["role"]
          # Process authenticated request

        {:error, :expired} ->
          # Token has expired, request re-authentication

        {:error, :invalid_signature} ->
          # Token is tampered or using wrong key
          # Reject request

        {:error, reason} ->
          # Other errors (malformed, missing claims, etc.)
          # Reject request
      end
  """

  use Joken.Config

  @role_scanner "scanner"

  # ========================================================================
  # Configuration
  # ========================================================================

  @doc """
  Returns the secret key used for signing and verifying tokens.

  The secret key is read from application configuration. In production,
  this should be a strong random string of at least 32 bytes.
  """
  def secret_key do
    Application.get_env(:fastcheck, __MODULE__)
    |> Keyword.get(:secret_key) ||
      raise """
      FastCheck.Mobile.Token secret key not configured.
      Please set it in config/runtime.exs:

          config :fastcheck, FastCheck.Mobile.Token,
            secret_key: System.get_env("MOBILE_JWT_SECRET") || raise("MOBILE_JWT_SECRET not set")
      """
  end

  @doc """
  Returns the token TTL (time to live) in seconds.

  Defaults to 86400 seconds (24 hours) if not configured.
  """
  def token_ttl_seconds do
    Application.get_env(:fastcheck, __MODULE__)
    |> Keyword.get(:token_ttl_seconds, 86_400)
  end

  @doc """
  Returns the issuer claim value for tokens.

  Defaults to "fastcheck" if not configured.
  """
  def issuer do
    Application.get_env(:fastcheck, __MODULE__)
    |> Keyword.get(:issuer, "fastcheck")
  end

  @doc """
  Returns the algorithm used for signing tokens.

  Defaults to "HS256" (HMAC with SHA-256) if not configured.
  """
  def algorithm do
    Application.get_env(:fastcheck, __MODULE__)
    |> Keyword.get(:algorithm, "HS256")
  end

  # ========================================================================
  # Token Issuance
  # ========================================================================

  @doc """
  Issues a JWT token for a mobile scanner for the given event.

  The token expiration is set based on the event's end time if available,
  otherwise falls back to the configured TTL. This ensures tokens expire
  when the event ends, providing better security.

  The token includes the following claims:
  - `event_id` - The ID of the event (integer)
  - `role` - Always "scanner"
  - `iss` - Issuer (from config)
  - `iat` - Issued at (current Unix timestamp)
  - `exp` - Expiration (event end time or iat + token_ttl_seconds)

  ## Parameters

  - `event_id` - The integer ID of the event this token grants access to

  ## Returns

  - `{:ok, token}` - Successfully generated token string
  - `{:error, reason}` - Failed to generate token

  ## Examples

      iex> {:ok, token} = FastCheck.Mobile.Token.issue_scanner_token(1)
      iex> String.starts_with?(token, "eyJ")
      true
  """
  @spec issue_scanner_token(integer()) :: {:ok, String.t()} | {:error, term()}
  def issue_scanner_token(event_id) when is_integer(event_id) and event_id > 0 do
    now = System.system_time(:second)
    exp = calculate_expiration(event_id, now)

    claims = %{
      "event_id" => event_id,
      "role" => @role_scanner,
      "iss" => issuer(),
      "iat" => now,
      "exp" => exp
    }

    signer = Joken.Signer.create(algorithm(), secret_key())

    case Joken.generate_and_sign(%{}, claims, signer) do
      {:ok, token, _claims} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  def issue_scanner_token(_event_id) do
    {:error, :invalid_event_id}
  end

  # Calculates token expiration based on event end time if available,
  # otherwise uses configured TTL.
  defp calculate_expiration(event_id, now) do
    case fetch_event_end_time(event_id) do
      {:ok, end_time_unix} when is_integer(end_time_unix) ->
        # Use event end time, but ensure it's not in the past
        # At least 1 hour from now
        max(end_time_unix, now + 3600)

      _ ->
        # Fallback to configured TTL
        now + token_ttl_seconds()
    end
  end

  # Fetches the event's end time from the database.
  defp fetch_event_end_time(event_id) do
    alias FastCheck.Repo
    alias FastCheck.Events.Event

    case Repo.get(Event, event_id) do
      %Event{tickera_end_date: %DateTime{} = end_date} ->
        {:ok, DateTime.to_unix(end_date)}

      %Event{tickera_end_date: nil} ->
        {:error, :no_end_date}

      nil ->
        {:error, :event_not_found}
    end
  rescue
    _ -> {:error, :fetch_failed}
  end

  # ========================================================================
  # Token Verification
  # ========================================================================

  @doc """
  Verifies a JWT token and returns its claims if valid.

  This function performs the following checks:
  1. Decodes the token structure
  2. Verifies the signature using the configured secret key
  3. Checks token expiration
  4. Validates required claims (event_id, role)
  5. Confirms the issuer matches the configured value

  ## Parameters

  - `token` - The JWT token string to verify

  ## Returns

  - `{:ok, claims}` - Token is valid, returns map of claims
  - `{:error, :expired}` - Token has expired
  - `{:error, :invalid_signature}` - Signature verification failed
  - `{:error, :malformed}` - Token structure is invalid
  - `{:error, :missing_claims}` - Required claims are missing

  ## Examples

      # Valid token
      iex> {:ok, token} = issue_scanner_token(1)
      iex> {:ok, claims} = verify_token(token)
      iex> claims["event_id"]
      1

      # Expired token
      iex> verify_token(expired_token)
      {:error, :expired}

      # Invalid signature
      iex> verify_token(tampered_token)
      {:error, :invalid_signature}
  """
  @spec verify_token(String.t()) ::
          {:ok, map()}
          | {:error,
             :expired | :invalid_signature | :malformed | :missing_claims | :invalid_issuer}
  def verify_token(token) when is_binary(token) do
    signer = Joken.Signer.create(algorithm(), secret_key())

    with {:ok, claims} <- Joken.verify(token, signer),
         :ok <- validate_expiration(claims),
         :ok <- validate_required_claims(claims),
         :ok <- validate_issuer(claims) do
      {:ok, claims}
    else
      {:error, :token_expired} ->
        {:error, :expired}

      {:error, :signature_error} ->
        {:error, :invalid_signature}

      {:error, reason}
      when reason in [:expired, :invalid_signature, :malformed, :missing_claims, :invalid_issuer] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :malformed}
    end
  end

  def verify_token(_token), do: {:error, :malformed}

  # ========================================================================
  # Private Helpers
  # ========================================================================

  # Validates that the token has not expired.
  # Joken typically handles this, but we add explicit validation for clarity.
  defp validate_expiration(%{"exp" => exp}) when is_integer(exp) do
    now = System.system_time(:second)

    if exp > now do
      :ok
    else
      {:error, :expired}
    end
  end

  defp validate_expiration(_claims), do: {:error, :expired}

  # Validates that all required claims are present and valid.
  defp validate_required_claims(%{"event_id" => event_id, "role" => role})
       when is_integer(event_id) and event_id > 0 and role == @role_scanner do
    :ok
  end

  defp validate_required_claims(_claims), do: {:error, :missing_claims}

  defp validate_issuer(%{"iss" => iss}) when is_binary(iss) do
    if iss == issuer() do
      :ok
    else
      {:error, :invalid_issuer}
    end
  end

  defp validate_issuer(_claims), do: {:error, :invalid_issuer}

  @doc """
  Extracts the event_id from a token's claims.

  This is a convenience function for controllers/plugs that need
  to quickly extract the event_id after verification.

  ## Parameters

  - `claims` - The decoded token claims map

  ## Returns

  - `{:ok, event_id}` - Successfully extracted event_id
  - `{:error, :missing_event_id}` - event_id claim is missing or invalid

  ## Examples

      iex> claims = %{"event_id" => 123, "role" => "scanner"}
      iex> extract_event_id(claims)
      {:ok, 123}
  """
  @spec extract_event_id(map()) :: {:ok, integer()} | {:error, :missing_event_id}
  def extract_event_id(%{"event_id" => event_id}) when is_integer(event_id) and event_id > 0 do
    {:ok, event_id}
  end

  def extract_event_id(_claims), do: {:error, :missing_event_id}

  @doc """
  Extracts the role from a token's claims.

  ## Parameters

  - `claims` - The decoded token claims map

  ## Returns

  - `{:ok, role}` - Successfully extracted role
  - `{:error, :missing_role}` - role claim is missing

  ## Examples

      iex> claims = %{"event_id" => 123, "role" => "scanner"}
      iex> extract_role(claims)
      {:ok, "scanner"}
  """
  @spec extract_role(map()) :: {:ok, String.t()} | {:error, :missing_role}
  def extract_role(%{"role" => role}) when is_binary(role) do
    {:ok, role}
  end

  def extract_role(_claims), do: {:error, :missing_role}
end
