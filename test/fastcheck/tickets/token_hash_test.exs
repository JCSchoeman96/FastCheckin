defmodule FastCheck.Tickets.TokenHashTest do
  use ExUnit.Case, async: true

  alias FastCheck.Tickets.TokenHash

  test "hash/2 and verify/3 are purpose-bound" do
    plaintext = "same-plaintext-value"

    delivery_hash = TokenHash.hash(plaintext, :delivery)
    qr_hash = TokenHash.hash(plaintext, :qr)

    assert delivery_hash != qr_hash
    assert TokenHash.verify(plaintext, delivery_hash, :delivery)
    assert TokenHash.verify(plaintext, qr_hash, :qr)
    refute TokenHash.verify(plaintext, qr_hash, :delivery)
    refute TokenHash.verify(plaintext, delivery_hash, :qr)
  end

  test "hash/2 is deterministic for the same pepper and purpose" do
    plaintext = "deterministic-token"

    assert TokenHash.hash(plaintext, :delivery) == TokenHash.hash(plaintext, :delivery)
  end

  test "pepper/0 reads dedicated ticket token pepper config" do
    assert TokenHash.pepper() == Application.fetch_env!(:fastcheck, :ticket_token_pepper)
    refute TokenHash.pepper() == Application.fetch_env!(:fastcheck, :sales_hold_token_pepper)
  end
end
