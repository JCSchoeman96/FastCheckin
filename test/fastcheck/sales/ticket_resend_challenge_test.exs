defmodule FastCheck.Sales.TicketResendChallengeTest do
  use FastCheck.DataCase, async: false

  import FastCheck.TicketResendFixtures

  alias Ash.Changeset
  alias FastCheck.Repo
  alias FastCheck.Tickets.Resend.Otp

  test "challenge table has bounded audit columns and required indexes" do
    assert_table("sales_ticket_resend_challenges")

    assert_columns("sales_ticket_resend_challenges", [
      "id",
      "public_id",
      "sales_order_id",
      "ticket_issue_id",
      "conversation_id",
      "request_email_hash",
      "request_name_hash",
      "source_hash",
      "candidate_hash",
      "otp_hash",
      "status",
      "failure_reason",
      "failed_attempt_count",
      "expires_at",
      "verified_at",
      "consumed_at",
      "locked_until",
      "metadata",
      "inserted_at",
      "updated_at"
    ])

    assert_index("sales_ticket_resend_challenges_public_id_uidx")
    assert_index("ticket_resend_challenges_email_inserted_at_idx")
    assert_index("ticket_resend_challenges_source_inserted_at_idx")
    assert_index("ticket_resend_challenges_candidate_inserted_at_idx")
    assert_index("ticket_resend_challenges_status_expires_at_idx")
    assert_index("sales_ticket_resend_challenges_sales_order_id_idx")
    assert_index("sales_ticket_resend_challenges_ticket_issue_id_idx")
    assert_index("sales_orders_lower_buyer_email_status_inserted_at_idx")
  end

  test "Ash actions guard lifecycle transitions" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, challenge, _otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)

    assert {:ok, verified} =
             challenge
             |> Changeset.for_update(:mark_verified, %{verified_at: now}, actor: system_actor())
             |> Ash.update()

    assert verified.status == "verified"

    assert {:error, _} =
             verified
             |> Changeset.for_update(:mark_blocked, %{failure_reason: "late"},
               actor: system_actor()
             )
             |> Ash.update()

    assert {:ok, consumed} =
             verified
             |> Changeset.for_update(:mark_consumed, %{consumed_at: now}, actor: system_actor())
             |> Ash.update()

    assert consumed.status == "consumed"
  end

  test "inspect does not leak hashes, metadata, OTP, raw email, name, or phone" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, challenge, otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)

    inspected = inspect(challenge)

    refute inspected =~ challenge.otp_hash
    refute inspected =~ challenge.request_email_hash
    refute inspected =~ challenge.source_hash
    refute inspected =~ challenge.candidate_hash
    refute inspected =~ otp
    refute inspected =~ "resend@example.com"
    refute inspected =~ "Jamie Smith"
    refute inspected =~ "+27821234567"
  end

  defp assert_table(table) do
    assert %{num_rows: 1} =
             Repo.query!(
               "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
               [table]
             )
  end

  defp assert_columns(table, columns) do
    result =
      Repo.query!(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        """,
        [table]
      )

    actual = Enum.map(result.rows, &List.first/1)

    for column <- columns do
      assert column in actual
    end
  end

  defp assert_index(index_name) do
    assert %{num_rows: 1} =
             Repo.query!("SELECT 1 FROM pg_indexes WHERE indexname = $1", [index_name])
  end

  defp system_actor, do: %{actor_type: :system, id: "test"}
end
