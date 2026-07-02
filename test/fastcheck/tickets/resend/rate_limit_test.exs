defmodule FastCheck.Tickets.Resend.RateLimitTest do
  use FastCheck.DataCase, async: false

  import FastCheck.TicketResendFixtures

  alias FastCheck.Tickets.Resend.Otp
  alias FastCheck.Tickets.Resend.RateLimit

  test "blocks email and source lookup after configured 15 minute limits" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = challenge_attrs!()

    for _ <- 1..3 do
      assert {:ok, _challenge, nil} = Otp.issue(attrs, now)
    end

    assert {:error, :email_rate_limited} =
             RateLimit.check_lookup(attrs.request_email_hash, attrs.source_hash, now)
  end

  test "blocks candidate after configured daily limit" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = challenge_attrs!()

    for _ <- 1..3 do
      assert {:ok, _challenge, nil} = Otp.issue(attrs, now)
    end

    assert {:error, :candidate_rate_limited} =
             RateLimit.check_candidate(attrs.candidate_hash, now)
  end

  test "allows attempts outside the bounded windows" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = challenge_attrs!()

    assert :ok = RateLimit.check_lookup(attrs.request_email_hash, attrs.source_hash, now)
    assert :ok = RateLimit.check_candidate(attrs.candidate_hash, now)
  end
end
