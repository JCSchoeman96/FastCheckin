defmodule FastCheck.Observability.RedactorTest do
  use ExUnit.Case, async: true

  alias FastCheck.Observability.Redactor

  describe "redact_map/1" do
    test "filters buyer PII and phone fields" do
      input = %{
        buyer_name: "Secret Name",
        buyer_phone: "+27123456789",
        buyer_email: "secret@example.com",
        phone_e164: "+27123456789",
        recipient: "+27999888777"
      }

      result = Redactor.redact_map(input)

      assert result[:buyer_name] == Redactor.filtered()
      assert result[:buyer_phone] == "+27***6789"
      assert result[:buyer_email] == "j***@example.com"
      assert result[:phone_e164] == "+27***6789"
      assert result[:recipient] == "+27***8777"
    end

    test "filters payment, token, and raw provider fields" do
      input = %{
        authorization_url: "https://checkout.paystack.com/secret?access_code=abc",
        access_code: "paystack-access",
        delivery_token: "delivery-secret",
        delivery_token_hash: "hash-value",
        qr_token: "qr-secret",
        qr_token_hash: "qr-hash",
        raw_payload: %{"event" => "charge.success"},
        meta_access_token: "meta-token",
        paystack_secret_key: "sk_live_secret"
      }

      result = Redactor.redact_map(input)

      assert result[:authorization_url] == Redactor.filtered()
      assert result[:access_code] == Redactor.filtered()
      assert result[:delivery_token] == Redactor.filtered()
      assert result[:delivery_token_hash] == Redactor.filtered()
      assert result[:qr_token] == Redactor.filtered()
      assert result[:qr_token_hash] == Redactor.filtered()
      assert result[:raw_payload] == Redactor.filtered()
      assert result[:meta_access_token] == Redactor.filtered()
      assert result[:paystack_secret_key] == Redactor.filtered()
    end

    test "recursively filters nested maps and lists" do
      input = %{
        provider_payload: %{
          nested: %{
            raw_payload: %{"message" => "hello"},
            message_body: "WhatsApp secret body"
          }
        },
        items: [%{delivery_token: "nested-token"}]
      }

      result = Redactor.redact_map(input)

      assert get_in(result, [:provider_payload, :nested, :raw_payload]) == Redactor.filtered()

      assert get_in(result, [:provider_payload, :nested, :message_body]) ==
               Redactor.filtered_message()

      assert get_in(result, [:items, Access.at(0), :delivery_token]) == Redactor.filtered()
    end
  end

  describe "safe_metadata/1" do
    test "removes forbidden keys and idempotency_key from arbitrary metadata" do
      input = %{
        order_id: "order-1",
        status: "awaiting_payment",
        idempotency_key: "idem-secret",
        buyer_email: "secret@example.com",
        hold_token: "hold-secret",
        message_body: "secret body"
      }

      result = Redactor.safe_metadata(input)

      assert result == %{order_id: "order-1", status: "awaiting_payment"}
      refute Map.has_key?(result, :idempotency_key)
      refute Map.has_key?(result, :buyer_email)
      refute Map.has_key?(result, :hold_token)
      refute Map.has_key?(result, :message_body)
    end

    test "accepts keyword lists" do
      assert Redactor.safe_metadata(order_id: "order-1", buyer_phone: "+27111") == %{
               order_id: "order-1"
             }
    end
  end

  describe "value helpers" do
    test "redact_phone/1 masks phone numbers" do
      assert Redactor.redact_phone("+27123456789") == "+27***6789"
      assert Redactor.redact_phone(nil) == Redactor.filtered_phone()
    end

    test "redact_email/1 masks email addresses" do
      assert Redactor.redact_email("secret@example.com") == "j***@example.com"
    end

    test "redact_token/1 always filters" do
      assert Redactor.redact_token("any-token") == Redactor.filtered()
    end

    test "redact_url/1 fails closed on token-bearing and provider URLs" do
      assert Redactor.redact_url("https://checkout.paystack.com/secret?access_code=abc") ==
               Redactor.filtered()

      assert Redactor.redact_url("https://example.com/tickets/secret-delivery-token") ==
               Redactor.filtered()

      assert Redactor.redact_url("https://example.com/delivery/secret-delivery-token") ==
               Redactor.filtered()

      assert Redactor.redact_url("not a valid url %%") == Redactor.filtered()
    end

    test "redact_url/1 strips query params from clearly safe URLs" do
      assert Redactor.redact_url("https://example.com/events/123?utm_source=x") ==
               "https://example.com/events/123"

      assert Redactor.redact_url("https://example.com/path?token=secret") == Redactor.filtered()
    end

    test "redact_ticket_code/1 keeps suffix only" do
      assert Redactor.redact_ticket_code("25955-1234") == "***1234"
    end
  end

  describe "redact_map/2 preserve_safe_ids" do
    test "preserves safe operational ids when requested" do
      input = %{order_id: "order-1", payment_attempt_id: "pay-1", delivery_token: "secret"}

      result = Redactor.redact_map(input, preserve_safe_ids: true)

      assert result[:order_id] == "order-1"
      assert result[:payment_attempt_id] == "pay-1"
      assert result[:delivery_token] == Redactor.filtered()
    end
  end
end
