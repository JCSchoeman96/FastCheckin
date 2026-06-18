defmodule FastCheck.Tickets.QrPayloadTest do
  use ExUnit.Case, async: true

  alias FastCheck.Tickets.QrPayload
  alias FastCheck.Tickets.TokenHash

  test "build_for_scanner/1 returns plain ticket_code for current scanner compatibility" do
    ticket_code = "FC-abc123"

    assert QrPayload.build_for_scanner(ticket_code) == ticket_code
  end

  test "build_versioned/2 and parse/1 round-trip FC1 payloads" do
    value = "opaque-token"

    payload = QrPayload.build_versioned("FC1", value)
    assert payload == "FC1:opaque-token"
    assert {:ok, %{version: "FC1", value: ^value}} = QrPayload.parse(payload)
  end

  test "parse/1 returns explicit errors for malformed payloads" do
    assert {:error, :invalid_format} = QrPayload.parse("")
    assert {:error, :invalid_format} = QrPayload.parse("FC1:")
    assert {:error, :invalid_format} = QrPayload.parse(nil)
  end

  test "scanner payload does not include PII or provider identifiers" do
    ticket_code = "FC-scanner-safe"
    payload = QrPayload.build_for_scanner(ticket_code)

    refute payload =~ "buyer"
    refute payload =~ "order"
    refute payload =~ "paystack"
    refute payload =~ "http"
  end

  test "generate_qr_token/0 hashes with :qr purpose" do
    %{token: token, hash: hash} = QrPayload.generate_qr_token()

    assert is_binary(token)
    assert hash == TokenHash.hash(token, :qr)
    assert hash == QrPayload.hash_qr_token(token)
  end
end
