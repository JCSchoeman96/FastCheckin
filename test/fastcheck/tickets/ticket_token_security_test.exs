defmodule FastCheck.Tickets.TicketTokenSecurityTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FastCheck.Observability.Redactor
  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.QrPayload

  test "safe_metadata/1 strips plaintext delivery and qr tokens" do
    %{token: delivery_token, hash: delivery_hash} = DeliveryToken.generate()
    %{token: qr_token, hash: qr_hash} = QrPayload.generate_qr_token()

    metadata =
      Redactor.safe_metadata(%{
        delivery_token: delivery_token,
        delivery_token_hash: delivery_hash,
        qr_token: qr_token,
        qr_token_hash: qr_hash,
        correlation_id: "corr-123"
      })

    assert is_nil(metadata[:delivery_token])
    assert is_nil(metadata[:delivery_token_hash])
    assert is_nil(metadata[:qr_token])
    assert is_nil(metadata[:qr_token_hash])
    assert metadata[:correlation_id] == "corr-123"
  end

  test "logs do not include plaintext delivery tokens" do
    %{token: token} = DeliveryToken.generate()

    log =
      capture_log([level: :warning], fn ->
        require Logger

        Logger.warning("delivery debug", Redactor.safe_metadata(%{delivery_token: token}))
      end)

    refute log =~ token
    assert log =~ "delivery debug"
  end
end
