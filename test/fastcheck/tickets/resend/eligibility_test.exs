defmodule FastCheck.Tickets.Resend.EligibilityTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import FastCheck.TicketResendFixtures

  alias FastCheck.Repo
  alias FastCheck.Tickets.Resend.Eligibility
  alias FastCheck.Tickets.Resend.Request
  alias FastCheck.Tickets.Resend.Result

  @message "If we find a matching ticket, we will send a verification email."

  test "valid unique candidate creates OTP challenge with optional internal OTP return" do
    candidate =
      issued_ticket_candidate!(
        buyer_email: "resend@example.com",
        buyer_name: "Jamie Smith",
        delivery_token_expires_at: DateTime.utc_now() |> DateTime.add(-3600, :second)
      )

    before_snapshot =
      row_snapshot(candidate.order_id, candidate.ticket_issue_id, candidate.attendee.id)

    assert {:ok, result, %{otp: otp}} =
             Eligibility.request_otp_challenge(
               %Request{
                 name: " Jamie   Smith ",
                 email: "resend@example.com",
                 source: %{phone_e164: "+27821234567"},
                 correlation_id: "corr-1"
               },
               return_otp?: true
             )

    assert %Result{} = result
    assert result.public_status == :accepted
    assert result.customer_message == @message
    assert result.challenge_public_id
    assert otp =~ ~r/^\d{6}$/

    assert count_challenges() == 1

    assert row_snapshot(candidate.order_id, candidate.ticket_issue_id, candidate.attendee.id) ==
             before_snapshot

    row =
      Repo.one!(
        from c in "sales_ticket_resend_challenges",
          where: c.public_id == ^result.challenge_public_id,
          select: map(c, [:otp_hash, :metadata, :sales_order_id, :ticket_issue_id])
      )

    assert row.sales_order_id == candidate.order_id
    assert row.ticket_issue_id == candidate.ticket_issue_id
    refute row.otp_hash == otp
    refute inspect(result) =~ candidate.buyer_email
    refute inspect(row.metadata) =~ candidate.buyer_email
    refute inspect(row.metadata) =~ candidate.ticket_code
  end

  test "request_otp_challenge always returns a 3-tuple and never places OTP in Result" do
    issued_ticket_candidate!()

    assert {:ok, result, nil} =
             Eligibility.request_otp_challenge(%Request{
               name: "Jamie Smith",
               email: "resend@example.com"
             })

    assert result.public_status == :accepted
    refute Map.has_key?(Map.from_struct(result), :otp)
    refute inspect(result) =~ ~r/\d{6}/
  end

  test "no match, wrong email, wrong name, and ambiguity fail closed with generic message" do
    issued_ticket_candidate!()

    for request <- [
          %Request{name: "Jamie Smith", email: "missing@example.com"},
          %Request{name: "Wrong Name", email: "resend@example.com"},
          %Request{name: "", email: "resend@example.com"}
        ] do
      assert_generic_rejected(request)
    end

    issued_ticket_candidate!(buyer_email: "ambiguous@example.com", buyer_name: "Jamie Smith")
    issued_ticket_candidate!(buyer_email: "ambiguous@example.com", buyer_name: "Jamie Smith")

    assert {:ok, result, nil} =
             Eligibility.request_otp_challenge(%Request{
               name: "Jamie Smith",
               email: "ambiguous@example.com"
             })

    assert result.public_status == :generic_rejected
    assert result.customer_message == @message
  end

  test "invalid order states fail closed" do
    for status <- ["refunded", "cancelled", "expired", "manual_review"] do
      issued_ticket_candidate!(buyer_email: "#{status}@example.com", order_status: status)

      assert_generic_rejected(%Request{
        name: "Jamie Smith",
        email: "#{status}@example.com"
      })
    end
  end

  test "invalid ticket states fail closed" do
    issued_ticket_candidate!(buyer_email: "pending@example.com", ticket_status: "pending")
    issued_ticket_candidate!(buyer_email: "revoked@example.com", ticket_status: "revoked")
    issued_ticket_candidate!(buyer_email: "scanner@example.com", scanner_status: "revoked")

    issued_ticket_candidate!(
      buyer_email: "revoked-at@example.com",
      revoked_at: DateTime.utc_now()
    )

    for email <- [
          "pending@example.com",
          "revoked@example.com",
          "scanner@example.com",
          "revoked-at@example.com"
        ] do
      assert_generic_rejected(%Request{name: "Jamie Smith", email: email})
    end
  end

  test "archived event and not-scannable/non-completed attendee fail closed" do
    issued_ticket_candidate!(buyer_email: "archived@example.com", event_status: "archived")

    issued_ticket_candidate!(
      buyer_email: "not-scan@example.com",
      scan_eligibility: "not_scannable"
    )

    issued_ticket_candidate!(buyer_email: "pending-pay@example.com", payment_status: "pending")

    for email <- ["archived@example.com", "not-scan@example.com", "pending-pay@example.com"] do
      assert_generic_rejected(%Request{name: "Jamie Smith", email: email})
    end
  end

  test "rate-limited request returns generic customer message and creates no new challenge" do
    attrs = challenge_attrs!(normalized_email: "limited@example.com")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for _ <- 1..3 do
      assert {:ok, _challenge, nil} = FastCheck.Tickets.Resend.Otp.issue(attrs, now)
    end

    before_count = count_challenges()
    issued_ticket_candidate!(buyer_email: "limited@example.com")

    assert {:ok, result, nil} =
             Eligibility.request_otp_challenge(%Request{
               name: "Jamie Smith",
               email: "limited@example.com"
             })

    assert result.public_status == :rate_limited
    assert result.customer_message == @message
    assert count_challenges() == before_count
  end

  test "does not create delivery attempts, rotate delivery tokens, send email, send WhatsApp, or generate PDF" do
    candidate = issued_ticket_candidate!()

    before_snapshot =
      row_snapshot(candidate.order_id, candidate.ticket_issue_id, candidate.attendee.id)

    assert {:ok, result, nil} =
             Eligibility.request_otp_challenge(%Request{
               name: "Jamie Smith",
               email: "resend@example.com"
             })

    assert result.public_status == :accepted

    assert row_snapshot(candidate.order_id, candidate.ticket_issue_id, candidate.attendee.id) ==
             before_snapshot

    assert [] = all_enqueued()
  end

  defp assert_generic_rejected(request) do
    before_count = count_challenges()

    assert {:ok, result, nil} = Eligibility.request_otp_challenge(request)
    assert result.public_status == :generic_rejected
    assert result.customer_message == @message
    assert count_challenges() == before_count
  end
end
