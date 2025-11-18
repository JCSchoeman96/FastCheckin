defmodule FastCheck.Crypto do
  @moduledoc """
  Symmetric encryption helper used to protect external credentials at rest.
  """

  require Logger

  alias Plug.Crypto.{KeyGenerator, MessageEncryptor}

  @encryption_salt "fastcheck:tickera:enc"
  @signing_salt "fastcheck:tickera:sig"

  @doc """
  Encrypts the provided binary using the application secret key base.

  Returns `{:ok, ciphertext}` on success.
  """
  @spec encrypt(binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(value) when is_binary(value) do
    with {:ok, secret_key_base} <- secret_key_base(),
         {:ok, ciphertext} <- do_encrypt(secret_key_base, value) do
      {:ok, ciphertext}
    else
      {:error, reason} ->
        Logger.error("Credential encryption failed: #{inspect(reason)}")
        {:error, :encryption_failed}
    end
  rescue
    exception ->
      Logger.error("Credential encryption exception: #{Exception.message(exception)}")
      {:error, :encryption_failed}
  end

  def encrypt(_), do: {:error, :invalid_data}

  @doc """
  Decrypts a ciphertext produced by `encrypt/1`.
  """
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, :decryption_failed}
  def decrypt(ciphertext) when is_binary(ciphertext) do
    with {:ok, secret_key_base} <- secret_key_base(),
         {:ok, plaintext} <- do_decrypt(secret_key_base, ciphertext) do
      {:ok, plaintext}
    else
      {:error, _reason} -> {:error, :decryption_failed}
    end
  rescue
    _exception -> {:error, :decryption_failed}
  end

  def decrypt(_), do: {:error, :decryption_failed}

  defp do_encrypt(secret_key_base, value) do
    {secret, sign_secret} = derive_secrets(secret_key_base)
    {:ok, MessageEncryptor.encrypt(value, secret, sign_secret)}
  rescue
    exception -> {:error, exception}
  end

  defp do_decrypt(secret_key_base, ciphertext) do
    {secret, sign_secret} = derive_secrets(secret_key_base)
    {:ok, MessageEncryptor.decrypt(ciphertext, secret, sign_secret)}
  rescue
    _exception -> {:error, :invalid_ciphertext}
  end

  defp derive_secrets(secret_key_base) do
    secret = KeyGenerator.generate(secret_key_base, @encryption_salt, length: 32, iterations: 1000)
    sign_secret = KeyGenerator.generate(secret_key_base, @signing_salt, length: 32, iterations: 1000)
    {secret, sign_secret}
  end

  defp secret_key_base do
    case fetch_endpoint_secret() do
      nil -> {:error, :missing_secret_key_base}
      secret -> {:ok, secret}
    end
  end

  defp fetch_endpoint_secret do
    case fastcheck_endpoint_secret() do
      nil -> runtime_endpoint_secret()
      secret -> secret
    end
  end

  defp fastcheck_endpoint_secret do
    try do
      FastCheckWeb.Endpoint.config(:secret_key_base)
    rescue
      _ -> nil
    end
  end

  defp runtime_endpoint_secret do
    Application.get_env(:fastcheck, FastCheckWeb.Endpoint)
    |> case do
      nil -> nil
      config -> Keyword.get(config, :secret_key_base)
    end
  end
end
