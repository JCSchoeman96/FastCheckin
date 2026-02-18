defmodule FastCheck.Crypto do
  @moduledoc """
  Symmetric encryption helpers backed by a master key configured for the app.
  """

  alias Plug.Crypto.{KeyGenerator, MessageEncryptor}

  @doc """
  Encrypts the given `plaintext` and returns a Base64 encoded ciphertext safe for storage.
  """
  @spec encrypt(binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(plaintext) when is_binary(plaintext) do
    try do
      ciphertext =
        plaintext
        |> MessageEncryptor.encrypt(encryption_secret(), signing_secret())
        |> Base.encode64()

      {:ok, ciphertext}
    rescue
      error -> {:error, error}
    end
  end

  def encrypt(_), do: {:error, :invalid_plaintext}

  @doc """
  Decrypts the given Base64 encoded ciphertext and returns the plaintext on success.
  """
  @spec decrypt(binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt(ciphertext) when is_binary(ciphertext) do
    with {:ok, encoded} <- Base.decode64(ciphertext),
         {:ok, plaintext} <- do_decrypt(encoded) do
      {:ok, plaintext}
    else
      :error -> {:error, :invalid_base64}
      {:error, reason} -> {:error, reason}
    end
  end

  def decrypt(_), do: {:error, :invalid_ciphertext}

  defp do_decrypt(encoded) do
    try do
      case MessageEncryptor.decrypt(encoded, encryption_secret(), signing_secret()) do
        {:ok, plaintext} when is_binary(plaintext) ->
          {:ok, plaintext}

        :error ->
          {:error, :invalid_ciphertext}

        _other ->
          {:error, :invalid_ciphertext}
      end
    rescue
      _ -> {:error, :invalid_ciphertext}
    end
  end

  defp encryption_secret do
    derive_secret("fastcheck:encryption")
  end

  defp signing_secret do
    derive_secret("fastcheck:signing")
  end

  defp derive_secret(salt) do
    KeyGenerator.generate(master_key(), salt, iterations: 1000, length: 32)
  end

  defp master_key do
    Application.fetch_env!(:fastcheck, :encryption_key)
  end
end
