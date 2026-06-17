defmodule FastCheck.Payments.Paystack.WebhookVerifierTest do
  use ExUnit.Case, async: true

  alias FastCheck.Payments.Paystack.WebhookVerifier

  test "valid_signature?/3 accepts valid raw-body signature" do
    raw_body = ~s({"event":"charge.success","data":{"reference":"FC-1"}})
    secret = "sk_test_fake_key"

    signature =
      :crypto.mac(:hmac, :sha512, secret, raw_body)
      |> Base.encode16(case: :lower)

    assert WebhookVerifier.valid_signature?(raw_body, signature, secret)
  end

  test "verify/3 rejects invalid signatures" do
    raw_body = ~s({"event":"charge.success","data":{"reference":"FC-1"}})
    secret = "sk_test_fake_key"

    assert {:error, error} = WebhookVerifier.verify(raw_body, "bad-signature", secret_key: secret)
    assert error.type == :invalid_signature
  end

  test "signature check uses raw body bytes (re-encoding changes digest)" do
    raw_body = ~S({"a":1, "b":2})
    secret = "sk_test_fake_key"

    signature =
      :crypto.mac(:hmac, :sha512, secret, raw_body)
      |> Base.encode16(case: :lower)

    refute WebhookVerifier.valid_signature?(~S({"a":1,"b":2}), signature, secret)
  end
end
