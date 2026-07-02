defmodule FastCheck.Tickets.Resend.EmailOtpTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import FastCheck.TicketResendFixtures
  import Swoosh.TestAssertions

  alias FastCheck.Repo
  alias FastCheck.Tickets.Resend.EmailOtp
  alias FastCheck.Tickets.Resend.Otp
  alias FastCheck.Tickets.Resend.Request
  alias FastCheck.Tickets.Resend.Result

  @message "If we find a matching ticket, we will send a verification email."

  setup :set_swoosh_global

  test "accepted request sends one OTP email to matched stored buyer email" do
    candidate =
      issued_ticket_candidate!(
        buyer_email: "resend@example.com",
        buyer_name: "Jamie Smith",
        delivery_token_expires_at: DateTime.utc_now() |> DateTime.add(-3600, :second)
      )

    before_snapshot =
      row_snapshot(candidate.order_id, candidate.ticket_issue_id, candidate.attendee.id)

    assert {:ok, result} =
             EmailOtp.request_email_otp(%Request{
               name: "Jamie Smith",
               email: "resend@example.com",
               source: %{phone_e164: "+27821234567"}
             })

    assert %Result{} = result
    assert result.public_status == :accepted
    assert result.customer_message == @message
    assert result.challenge_public_id
    refute inspect(result) =~ result.challenge_public_id
    refute inspect(result) =~ ~r/\d{6}/

    assert_email_sent(fn email ->
      assert {"", "resend@example.com"} in email.to
      assert email.subject == "Your FastCheck verification code"
      assert email.text_body =~ ~r/\b\d{6}\b/
      assert email.html_body =~ ~r/\b\d{6}\b/
      assert email.text_body =~ "expires in 10 minutes"
      refute String.downcase(email.subject) =~ "payment"
      refute String.downcase(email.text_body) =~ "payment"
      refute String.downcase(email.text_body) =~ "token"
      refute String.downcase(email.text_body) =~ "qr"
      refute email.text_body =~ candidate.ticket_code
      refute email.text_body =~ "http://"
      refute email.text_body =~ "https://"
      true
    end)

    assert row_snapshot(candidate.order_id, candidate.ticket_issue_id, candidate.attendee.id) ==
             before_snapshot

    row =
      Repo.one!(
        from c in "sales_ticket_resend_challenges",
          where: c.public_id == ^result.challenge_public_id,
          select: map(c, [:metadata, :otp_hash])
      )

    refute inspect(row.metadata) =~ "resend@example.com"
    refute inspect(row.metadata) =~ ~r/\b\d{6}\b/
    refute row.otp_hash =~ ~r/\b\d{6}\b/
    assert [] == all_enqueued()
  end

  test "accepted result with missing OTP payload sends no email and returns unchanged result" do
    accepted_result =
      Result.new(:accepted, :otp_challenge_created, challenge_public_id: "public-id-123")

    eligibility_fun = fn _request, _opts ->
      {:ok, accepted_result, nil}
    end

    assert {:ok, ^accepted_result} =
             EmailOtp.request_email_otp(
               %Request{name: "Jamie Smith", email: "stored-buyer@example.com"},
               eligibility_fun: eligibility_fun
             )

    assert_no_email_sent()
  end

  test "rejected, ambiguous, invalid input, and no-match requests send no email" do
    issued_ticket_candidate!(buyer_email: "resend@example.com", buyer_name: "Jamie Smith")
    issued_ticket_candidate!(buyer_email: "ambiguous@example.com", buyer_name: "Jamie Smith")
    issued_ticket_candidate!(buyer_email: "ambiguous@example.com", buyer_name: "Jamie Smith")

    for request <- [
          %Request{name: "Jamie Smith", email: "missing@example.com"},
          %Request{name: "Wrong Name", email: "resend@example.com"},
          %Request{name: "Jamie Smith", email: "ambiguous@example.com"},
          %Request{name: "", email: "resend@example.com"}
        ] do
      assert {:ok, result} = EmailOtp.request_email_otp(request)
      assert result.customer_message == @message
    end

    assert_no_email_sent()
  end

  test "rate-limited request sends no email" do
    attrs = challenge_attrs!(normalized_email: "limited@example.com")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for _ <- 1..3 do
      assert {:ok, _challenge, nil} = Otp.issue(attrs, now)
    end

    issued_ticket_candidate!(buyer_email: "limited@example.com")

    assert {:ok, result} =
             EmailOtp.request_email_otp(%Request{
               name: "Jamie Smith",
               email: "limited@example.com"
             })

    assert result.public_status == :rate_limited
    assert_no_email_sent()
  end

  test "mailer failure is swallowed and returns unchanged generic result" do
    issued_ticket_candidate!(buyer_email: "resend@example.com", buyer_name: "Jamie Smith")

    assert {:ok, result} =
             EmailOtp.request_email_otp(
               %Request{name: "Jamie Smith", email: "resend@example.com"},
               deliver_fun: fn _email -> {:error, :mailer_unavailable} end
             )

    assert result.public_status == :accepted
    assert result.customer_message == @message
    assert_no_email_sent()
  end

  test "verify_otp delegates to OTP contract and does not send email" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, challenge, otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)

    assert {:ok, verified} =
             EmailOtp.verify_otp(challenge.public_id, otp, now: DateTime.add(now, 1, :second))

    assert verified.status == "verified"

    assert {:error, :already_verified} =
             EmailOtp.verify_otp(challenge.public_id, otp, now: DateTime.add(now, 2, :second))

    assert {:error, :invalid_or_expired} =
             EmailOtp.verify_otp("missing-public-id", "000000", now: now)

    {:ok, expired_challenge, expired_otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)

    assert {:error, :invalid_or_expired} =
             EmailOtp.verify_otp(expired_challenge.public_id, expired_otp,
               now: DateTime.add(now, 601, :second)
             )

    {:ok, blocked_challenge, _blocked_otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)

    for attempt <- 1..5 do
      assert {:error, :invalid_or_expired} =
               EmailOtp.verify_otp(
                 blocked_challenge.public_id,
                 "000000",
                 now: DateTime.add(now, attempt, :second)
               )
    end

    assert {:error, :locked} =
             EmailOtp.verify_otp(
               blocked_challenge.public_id,
               "000000",
               now: DateTime.add(now, 6, :second)
             )

    assert_no_email_sent()
  end
end
