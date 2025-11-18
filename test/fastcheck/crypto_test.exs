defmodule FastCheck.CryptoTest do
  use ExUnit.Case, async: true
  use Bitwise

  alias FastCheck.Crypto

  describe "encrypt/1 and decrypt/1" do
    test "round trip" do
      plaintext = "secret payload"

      assert {:ok, ciphertext} = Crypto.encrypt(plaintext)
      refute ciphertext == plaintext
      assert {:ok, ^plaintext} = Crypto.decrypt(ciphertext)
    end

    test "handles tampered ciphertext" do
      {:ok, ciphertext} = Crypto.encrypt("data")

      tampered =
        ciphertext
        |> Base.decode64!()
        |> then(fn <<first, rest::binary>> -> <<bxor(first, 0xFF), rest::binary>> end)
        |> Base.encode64()

      assert {:error, :invalid_ciphertext} = Crypto.decrypt(tampered)
    end

    test "rejects invalid base64" do
      assert {:error, :invalid_base64} = Crypto.decrypt("not-base64!!")
    end
  end
end
