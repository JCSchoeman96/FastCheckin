defmodule FastCheck.Tickets.Resend.ResultTest do
  use ExUnit.Case, async: true

  alias FastCheck.Tickets.Resend.Result

  @message "If we find a matching ticket, we will send a verification email."

  test "all public statuses use the same generic customer message" do
    for status <- [:accepted, :generic_rejected, :rate_limited] do
      result = Result.new(status, :test_reason)

      assert result.customer_message == @message
      assert result.public_status == status
    end
  end

  test "safe metadata and inspect do not expose protected internals" do
    result =
      Result.new(:accepted, :otp_challenge_created,
        challenge_public_id: "public-id",
        metadata: %{
          order_id: 1,
          buyer_email: "secret@example.com",
          buyer_phone: "+27821234567",
          delivery_token_hash: "token-hash",
          access_code: "PAYSTACK"
        }
      )

    inspected = inspect(result)

    assert result.safe_metadata[:order_id] == 1
    refute inspected =~ "secret@example.com"
    refute inspected =~ "+27821234567"
    refute inspected =~ "token-hash"
    refute inspected =~ "PAYSTACK"
  end
end
