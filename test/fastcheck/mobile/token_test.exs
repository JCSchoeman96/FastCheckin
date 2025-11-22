defmodule FastCheck.Mobile.TokenTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Mobile.Token
  alias Joken.Signer

  describe "issue_scanner_token/1" do
    test "generates a valid token for a valid event_id" do
      event_id = 123

      assert {:ok, token} = Token.issue_scanner_token(event_id)
      assert is_binary(token)
      assert String.starts_with?(token, "eyJ")
    end

    test "generated token contains event_id and role in claims" do
      event_id = 456

      assert {:ok, token} = Token.issue_scanner_token(event_id)
      assert {:ok, claims} = Token.verify_token(token)
      assert claims["event_id"] == event_id
      assert claims["role"] == "scanner"
    end

    test "generated token includes expiration time" do
      event_id = 789

      assert {:ok, token} = Token.issue_scanner_token(event_id)
      assert {:ok, claims} = Token.verify_token(token)
      assert is_integer(claims["exp"])
      assert is_integer(claims["iat"])
      # Expiration should be in the future
      assert claims["exp"] > claims["iat"]
    end

    test "rejects invalid event_id (negative)" do
      assert {:error, :invalid_event_id} = Token.issue_scanner_token(-1)
    end

    test "rejects invalid event_id (zero)" do
      assert {:error, :invalid_event_id} = Token.issue_scanner_token(0)
    end

    test "rejects invalid event_id (nil)" do
      assert {:error, :invalid_event_id} = Token.issue_scanner_token(nil)
    end
  end

  describe "verify_token/1" do
    test "successfully verifies a valid token" do
      event_id = 100

      {:ok, token} = Token.issue_scanner_token(event_id)
      assert {:ok, claims} = Token.verify_token(token)
      assert is_map(claims)
      assert claims["event_id"] == event_id
    end

    test "rejects a malformed token" do
      assert {:error, :malformed} = Token.verify_token("not-a-valid-token")
    end

    test "rejects an empty token" do
      assert {:error, :malformed} = Token.verify_token("")
    end

    test "rejects a tampered token" do
      {:ok, token} = Token.issue_scanner_token(123)
      # Tamper with the token by changing a character
      tampered = String.replace(token, "e", "a", global: false)
      assert {:error, _} = Token.verify_token(tampered)
    end

    test "rejects nil token" do
      assert {:error, :malformed} = Token.verify_token(nil)
    end

    test "validates the configured issuer" do
      {:ok, token} = Token.issue_scanner_token(200)

      assert {:ok, %{"iss" => iss}} = Token.verify_token(token)
      assert iss == Token.issuer()
    end

    test "rejects tokens with incorrect or missing issuer" do
      now = System.system_time(:second)
      signer = Signer.create(Token.algorithm(), Token.secret_key())

      wrong_issuer_claims = %{
        "event_id" => 1,
        "role" => "scanner",
        "iat" => now,
        "exp" => now + Token.token_ttl_seconds(),
        "iss" => "other-issuer"
      }

      assert {:ok, wrong_issuer_token, _} = Joken.generate_and_sign(wrong_issuer_claims, signer)
      assert {:error, :invalid_issuer} = Token.verify_token(wrong_issuer_token)

      missing_issuer_claims = Map.delete(wrong_issuer_claims, "iss")

      assert {:ok, missing_issuer_token, _} = Joken.generate_and_sign(missing_issuer_claims, signer)
      assert {:error, :invalid_issuer} = Token.verify_token(missing_issuer_token)
    end
  end

  describe "extract_event_id/1" do
    test "extracts event_id from valid claims" do
      claims = %{"event_id" => 999, "role" => "scanner"}
      assert {:ok, 999} = Token.extract_event_id(claims)
    end

    test "rejects claims without event_id" do
      claims = %{"role" => "scanner"}
      assert {:error, :missing_event_id} = Token.extract_event_id(claims)
    end

    test "rejects claims with invalid event_id type" do
      claims = %{"event_id" => "not-an-integer", "role" => "scanner"}
      assert {:error, :missing_event_id} = Token.extract_event_id(claims)
    end

    test "rejects claims with negative event_id" do
      claims = %{"event_id" => -1, "role" => "scanner"}
      assert {:error, :missing_event_id} = Token.extract_event_id(claims)
    end
  end

  describe "extract_role/1" do
    test "extracts role from valid claims" do
      claims = %{"event_id" => 123, "role" => "scanner"}
      assert {:ok, "scanner"} = Token.extract_role(claims)
    end

    test "rejects claims without role" do
      claims = %{"event_id" => 123}
      assert {:error, :missing_role} = Token.extract_role(claims)
    end

    test "rejects claims with non-string role" do
      claims = %{"event_id" => 123, "role" => 123}
      assert {:error, :missing_role} = Token.extract_role(claims)
    end
  end
end
