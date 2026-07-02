defmodule FastCheck.Tickets.Resend.HashTest do
  use ExUnit.Case, async: false

  alias FastCheck.Tickets.Resend.Hash

  @raw_email "secret@example.com"

  test "hashes are deterministic lower hex and do not expose raw inputs" do
    hash = Hash.email(@raw_email)

    assert hash == Hash.email(@raw_email)
    assert hash =~ ~r/^[0-9a-f]{64}$/
    refute hash =~ @raw_email
    refute inspect(Hash) =~ @raw_email
  end

  test "source and candidate hashes are deterministic" do
    assert Hash.source(%{conversation_id: 123}) == Hash.source(%{conversation_id: 123})

    assert Hash.source(%{phone_e164: "+27821234567"}) ==
             Hash.source(%{phone_e164: "+27821234567"})

    assert Hash.candidate(1, 2) == Hash.candidate(1, 2)
    assert Hash.otp("public", "123456") == Hash.otp("public", "123456")
  end

  test "missing resend pepper fails fast" do
    original = Application.get_env(:fastcheck, :ticket_resend)
    Application.put_env(:fastcheck, :ticket_resend, Keyword.delete(original, :hash_pepper))

    try do
      assert_raise KeyError, fn -> Hash.email(@raw_email) end
    after
      Application.put_env(:fastcheck, :ticket_resend, original)
    end
  end
end
