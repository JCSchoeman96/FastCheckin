defmodule FastCheck.Messaging.WhatsApp.WebhookVerifierTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Messaging.WhatsApp.WebhookVerifier

  test "verify_challenge/2 accepts valid Meta setup challenge" do
    params = %{
      "hub.mode" => "subscribe",
      "hub.verify_token" => WebhookTestSupport.verify_token(),
      "hub.challenge" => "123456"
    }

    assert {:ok, "123456"} =
             WebhookVerifier.verify_challenge(params, WebhookTestSupport.verify_token())
  end

  test "verify_challenge/2 rejects wrong mode token and missing challenge distinctly" do
    token = WebhookTestSupport.verify_token()

    assert {:error, :invalid_mode} =
             WebhookVerifier.verify_challenge(%{"hub.mode" => "unsubscribe"}, token)

    assert {:error, :invalid_verify_token} =
             WebhookVerifier.verify_challenge(
               %{"hub.mode" => "subscribe", "hub.verify_token" => "bad"},
               token
             )

    assert {:error, :missing_challenge} =
             WebhookVerifier.verify_challenge(
               %{"hub.mode" => "subscribe", "hub.verify_token" => token},
               token
             )
  end

  test "verify_signature/3 verifies sha256 header against exact raw body bytes" do
    raw_body = ~S({"a":1, "b":2})
    secret = WebhookTestSupport.app_secret()
    signature = WebhookTestSupport.sign_body(raw_body, secret)

    assert :ok = WebhookVerifier.verify_signature(raw_body, signature, secret)

    assert {:error, :invalid_signature} =
             WebhookVerifier.verify_signature(~S({"a":1,"b":2}), signature, secret)
  end

  test "verify_signature/3 rejects missing signature invalid signature and missing secret" do
    assert {:error, :missing_signature} =
             WebhookVerifier.verify_signature("{}", nil, WebhookTestSupport.app_secret())

    assert {:error, :invalid_signature} =
             WebhookVerifier.verify_signature("{}", "sha256=bad", WebhookTestSupport.app_secret())

    assert {:error, :missing_app_secret} =
             WebhookVerifier.verify_signature("{}", "sha256=bad", nil)
  end
end
