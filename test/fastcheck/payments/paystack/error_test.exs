defmodule FastCheck.Payments.Paystack.ErrorTest do
  use ExUnit.Case, async: true

  alias FastCheck.Payments.Paystack.Error

  test "sanitize_message redacts provider secrets and pii" do
    assert Error.sanitize_message("Unauthorized") == "Unauthorized"
    assert Error.sanitize_message("rate limit") == "rate limit"

    assert Error.sanitize_message("Invalid key sk_test_secret") == "paystack request failed"

    assert Error.sanitize_message("https://checkout.paystack.com/abc") ==
             "paystack request failed"

    assert Error.sanitize_message("access_code AC_123 is invalid") == "paystack request failed"
    assert Error.sanitize_message("buyer@example.com is invalid") == "paystack request failed"
    assert Error.sanitize_message("phone +27821234567 invalid") == "paystack request failed"
  end

  test "new/1 sanitizes message at construction time" do
    error =
      Error.new(%{
        type: :provider_error,
        message: "failed for buyer@example.com with access_code AC_123"
      })

    assert error.message == "paystack request failed"
  end

  test "inspect does not expose sensitive provider message content" do
    error =
      Error.new(%{
        type: :provider_error,
        message: "https://checkout.paystack.com/abc for buyer@example.com"
      })

    inspected = inspect(error)

    refute inspected =~ "checkout.paystack"
    refute inspected =~ "buyer@example.com"
    assert inspected =~ "paystack request failed"
  end
end
