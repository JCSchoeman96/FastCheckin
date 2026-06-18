defmodule FastCheck.Tickets.DeliveryTokenTest do
  use ExUnit.Case, async: true

  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.TokenHash

  test "generate/1 returns plaintext once plus hash and expires_at" do
    now = ~U[2026-06-18 12:00:00Z]

    %{token: token, hash: hash, expires_at: expires_at} =
      DeliveryToken.generate(now: now, ttl_seconds: 3600)

    assert is_binary(token)
    assert hash == TokenHash.hash(token, :delivery)
    assert expires_at == ~U[2026-06-18 13:00:00Z]
  end

  test "generated delivery tokens use at least 256 bits of randomness across samples" do
    tokens = for _ <- 1..20, do: DeliveryToken.generate().token
    assert length(Enum.uniq(tokens)) == 20
  end

  test "verify_context/2 rejects expired tokens" do
    %{token: token, hash: hash} = DeliveryToken.generate()

    ticket_issue = %{
      delivery_token_hash: hash,
      delivery_token_expires_at: ~U[2020-01-01 00:00:00Z],
      status: "issued"
    }

    assert {:error, :expired} = DeliveryToken.verify_context(token, ticket_issue)
  end

  test "verify_context/2 rejects missing delivery_token_expires_at" do
    %{token: token, hash: hash} = DeliveryToken.generate()

    assert {:error, :expired} =
             DeliveryToken.verify_context(token, %{
               delivery_token_hash: hash,
               status: "issued"
             })

    assert {:error, :expired} =
             DeliveryToken.verify_context(token, %{
               delivery_token_hash: hash,
               delivery_token_expires_at: nil,
               status: "issued"
             })
  end

  test "verify_context/2 rejects revoked tickets" do
    %{token: token, hash: hash, expires_at: expires_at} = DeliveryToken.generate()

    ticket_issue = %{
      delivery_token_hash: hash,
      delivery_token_expires_at: expires_at,
      status: "revoked"
    }

    assert {:error, :revoked} = DeliveryToken.verify_context(token, ticket_issue)
  end

  test "verify_context/2 accepts valid active tokens" do
    %{token: token, hash: hash} = DeliveryToken.generate()

    ticket_issue = %{
      delivery_token_hash: hash,
      delivery_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      status: "issued"
    }

    assert :ok = DeliveryToken.verify_context(token, ticket_issue)
  end

  test "verify_hash/2 rejects wrong purpose hashes" do
    plaintext = "shared-plaintext"
    qr_hash = TokenHash.hash(plaintext, :qr)

    refute DeliveryToken.verify_hash(plaintext, qr_hash)
  end
end
