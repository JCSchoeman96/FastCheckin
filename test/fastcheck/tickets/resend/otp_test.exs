defmodule FastCheck.Tickets.Resend.OtpTest do
  use FastCheck.DataCase, async: false

  import FastCheck.TicketResendFixtures

  alias FastCheck.Repo
  alias FastCheck.Sales.TicketResendChallenge
  alias FastCheck.Tickets.Resend.Otp

  test "issue stores only OTP hash and returns plaintext only when requested" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = challenge_attrs!()

    assert {:ok, challenge, nil} = Otp.issue(attrs, now)
    assert challenge.status == "pending"
    assert challenge.otp_hash
    refute inspect(challenge) =~ challenge.otp_hash

    assert {:ok, challenge_with_otp, otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)
    assert otp =~ ~r/^\d{6}$/
    refute challenge_with_otp.otp_hash == otp
    refute inspect(challenge_with_otp) =~ otp
  end

  test "correct OTP verifies once and cannot be reused" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, challenge, otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)

    assert {:ok, verified} = Otp.verify(challenge.public_id, otp, DateTime.add(now, 1, :second))
    assert verified.status == "verified"
    assert verified.verified_at

    assert {:error, :already_used} =
             Otp.verify(challenge.public_id, otp, DateTime.add(now, 2, :second))
  end

  test "wrong OTP increments attempts and locks after max failures" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, challenge, _otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)

    for attempt <- 1..4 do
      assert {:error, :invalid} =
               Otp.verify(challenge.public_id, "000000", DateTime.add(now, attempt, :second))
    end

    reloaded = Ash.get!(TicketResendChallenge, challenge.id, actor: system_actor())
    assert reloaded.status == "pending"
    assert reloaded.failed_attempt_count == 4

    assert {:error, :invalid} =
             Otp.verify(challenge.public_id, "000000", DateTime.add(now, 5, :second))

    blocked = Ash.get!(TicketResendChallenge, challenge.id, actor: system_actor())
    assert blocked.status == "blocked"
    assert blocked.failed_attempt_count == 5
    assert blocked.locked_until
  end

  test "expired OTP marks challenge expired" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, challenge, otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)

    assert {:error, :expired} =
             Otp.verify(challenge.public_id, otp, DateTime.add(now, 601, :second))

    expired = Ash.get!(TicketResendChallenge, challenge.id, actor: system_actor())
    assert expired.status == "expired"
  end

  test "plain OTP is not stored in the challenge row" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, challenge, otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)

    row =
      Repo.one!(
        from c in "sales_ticket_resend_challenges",
          where: c.id == ^challenge.id,
          select:
            map(c, [:otp_hash, :metadata, :request_email_hash, :source_hash, :candidate_hash])
      )

    refute row.otp_hash == otp
    refute inspect(row.metadata) =~ otp
    refute inspect(row) =~ "resend@example.com"
    refute inspect(row) =~ "Jamie Smith"
  end

  defp system_actor, do: %{actor_type: :system, id: "test"}
end
