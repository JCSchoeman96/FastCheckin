defmodule FastCheck.Sales.DeliveryAttemptTest do
  use FastCheck.DataCase, async: false

  import FastCheck.TicketResendFixtures

  alias Ash.Changeset
  alias FastCheck.Sales.DeliveryAttempt
  alias FastCheck.Tickets.Resend.Otp

  test "create_queued accepts safe verified resend audit fields" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {:ok, challenge, _otp} = Otp.issue(challenge_attrs!(), now, return_otp?: true)

    assert {:ok, attempt} =
             DeliveryAttempt
             |> Changeset.for_create(
               :create_queued,
               %{
                 sales_order_id: challenge.sales_order_id,
                 ticket_issue_id: challenge.ticket_issue_id,
                 ticket_resend_challenge_id: challenge.id,
                 channel: "whatsapp",
                 provider: "meta",
                 recipient: "+27***4567",
                 delivery_reason: "verified_ticket_resend",
                 attempt_number: 1,
                 correlation_id: "corr-delivery-attempt-test"
               },
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    assert attempt.status == "queued"
    assert attempt.delivery_reason == "verified_ticket_resend"
    assert attempt.ticket_resend_challenge_id == challenge.id
  end

  test "normal create_queued leaves resend audit fields nil" do
    attrs = challenge_attrs!()

    assert {:ok, attempt} =
             DeliveryAttempt
             |> Changeset.for_create(
               :create_queued,
               %{
                 sales_order_id: attrs.sales_order_id,
                 ticket_issue_id: attrs.ticket_issue_id,
                 channel: "whatsapp",
                 provider: "meta",
                 recipient: "+27***4567",
                 attempt_number: 1,
                 correlation_id: "corr-normal-delivery-attempt-test"
               },
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    assert attempt.status == "queued"
    assert attempt.delivery_reason == nil
    assert attempt.ticket_resend_challenge_id == nil
  end

  test "queued attempts become provider_accepted with a WAMID and no sent timestamp" do
    attempt = create_queued_attempt!()
    accepted_at = ~U[2026-07-05 10:00:00Z]

    assert {:ok, updated} =
             update_attempt(attempt, :mark_provider_accepted, %{
               provider_message_id: "wamid.lifecycle-accepted",
               provider_accepted_at: accepted_at
             })

    assert updated.status == "provider_accepted"
    assert updated.provider_message_id == "wamid.lifecycle-accepted"
    assert updated.provider_accepted_at == accepted_at
    assert updated.provider_status == "accepted"
    assert updated.provider_status_at == accepted_at
    assert is_nil(updated.sent_at)
  end

  test "provider acceptance rejects a blank WAMID" do
    attempt = create_queued_attempt!()

    assert {:error, error} =
             update_attempt(attempt, :mark_provider_accepted, %{
               provider_message_id: "  ",
               provider_accepted_at: ~U[2026-07-05 10:00:00Z]
             })

    assert inspect(error) =~ "provider_message_id"
  end

  test "provider acceptance clears a stale sent timestamp" do
    attempt = create_queued_attempt!()
    sent_at = ~U[2026-07-05 09:59:00Z]

    Repo.query!(
      "UPDATE sales_delivery_attempts SET sent_at = $1 WHERE id = $2",
      [sent_at, attempt.id]
    )

    reloaded =
      DeliveryAttempt
      |> Ash.Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    assert reloaded.sent_at == sent_at

    assert {:ok, updated} =
             update_attempt(reloaded, :mark_provider_accepted, %{
               provider_message_id: "wamid.lifecycle-clears-sent-at",
               provider_accepted_at: ~U[2026-07-05 10:00:00Z]
             })

    assert updated.status == "provider_accepted"
    assert is_nil(updated.sent_at)
  end

  test "provider status actions store their evidence timestamps" do
    accepted_at = ~U[2026-07-05 10:00:00Z]
    sent_at = ~U[2026-07-05 10:01:00Z]
    delivered_at = ~U[2026-07-05 10:02:00Z]
    read_at = ~U[2026-07-05 10:03:00Z]

    {:ok, accepted} =
      create_queued_attempt!()
      |> update_attempt(:mark_provider_accepted, %{
        provider_message_id: "wamid.lifecycle-evidence",
        provider_accepted_at: accepted_at
      })

    assert {:ok, sent} = update_attempt(accepted, :mark_sent, %{sent_at: sent_at})
    assert sent.status == "sent"
    assert sent.provider_message_id == "wamid.lifecycle-evidence"
    assert sent.provider_status == "sent"
    assert sent.provider_status_at == sent_at
    assert sent.sent_at == sent_at

    assert {:ok, delivered} =
             update_attempt(sent, :mark_delivered, %{delivered_at: delivered_at})

    assert delivered.status == "delivered"
    assert delivered.provider_message_id == "wamid.lifecycle-evidence"
    assert delivered.provider_status == "delivered"
    assert delivered.provider_status_at == delivered_at
    assert delivered.delivered_at == delivered_at

    assert {:ok, read} = update_attempt(delivered, :mark_read, %{read_at: read_at})
    assert read.status == "read"
    assert read.provider_message_id == "wamid.lifecycle-evidence"
    assert read.provider_status == "read"
    assert read.provider_status_at == read_at
    assert read.read_at == read_at
  end

  test "later provider evidence actions cannot replace the accepted WAMID" do
    for {action, timestamp_field, timestamp} <- [
          {:mark_sent, :sent_at, ~U[2026-07-05 10:01:00Z]},
          {:mark_delivered, :delivered_at, ~U[2026-07-05 10:02:00Z]},
          {:mark_read, :read_at, ~U[2026-07-05 10:03:00Z]}
        ] do
      accepted_wamid = "wamid.lifecycle-immutable-#{action}"
      {:ok, accepted} = provider_accepted_attempt!(accepted_wamid)

      result =
        update_attempt(accepted, action, %{
          timestamp_field => timestamp,
          provider_message_id: "wamid.lifecycle-replacement"
        })

      case result do
        {:ok, updated} -> assert updated.provider_message_id == accepted_wamid
        {:error, _error} -> :ok
      end

      reloaded =
        DeliveryAttempt
        |> Ash.Query.for_read(:get_by_id, %{id: accepted.id})
        |> Ash.read_one!(authorize?: false)

      assert reloaded.provider_message_id == accepted_wamid
    end
  end

  test "provider success evidence may skip intermediate states" do
    for {action, final_status} <- [
          {:mark_delivered, "delivered"},
          {:mark_read, "read"}
        ] do
      {:ok, accepted} = provider_accepted_attempt!()
      timestamp = ~U[2026-07-05 10:05:00Z]

      attrs =
        case action do
          :mark_delivered -> %{delivered_at: timestamp}
          :mark_read -> %{read_at: timestamp}
        end

      assert {:ok, updated} = update_attempt(accepted, action, attrs)
      assert updated.status == final_status
    end

    {:ok, sent} = provider_accepted_attempt!()
    {:ok, sent} = update_attempt(sent, :mark_sent, %{sent_at: ~U[2026-07-05 10:06:00Z]})

    assert {:ok, read} =
             update_attempt(sent, :mark_read, %{read_at: ~U[2026-07-05 10:07:00Z]})

    assert read.status == "read"
  end

  test "lifecycle actions reject invalid regressions and terminal updates" do
    queued = create_queued_attempt!()

    assert {:error, _} = update_attempt(queued, :mark_sent, %{sent_at: ~U[2026-07-05 10:10:00Z]})

    {:ok, accepted} = provider_accepted_attempt!()

    {:ok, delivered} =
      update_attempt(accepted, :mark_delivered, %{delivered_at: ~U[2026-07-05 10:11:00Z]})

    assert {:error, _} =
             update_attempt(delivered, :mark_provider_accepted, %{
               provider_message_id: "wamid.lifecycle-regression"
             })

    {:ok, read} = update_attempt(delivered, :mark_read, %{read_at: ~U[2026-07-05 10:12:00Z]})

    assert {:error, _} =
             update_attempt(read, :mark_delivered, %{delivered_at: ~U[2026-07-05 10:13:00Z]})

    {:ok, fallback} =
      update_attempt(create_queued_attempt!(), :mark_fallback_required, %{
        failure_reason: "outside_window",
        fallback_channel: "manual_review"
      })

    assert {:error, _} =
             update_attempt(fallback, :mark_manual_review, %{
               failure_reason: "still_uncertain",
               fallback_channel: "manual_review"
             })
  end

  test "failed attempts may move to manual_review and record failed_at" do
    failed_at = ~U[2026-07-05 10:15:00Z]

    {:ok, failed} =
      update_attempt(create_queued_attempt!(), :mark_failed, %{
        provider_error_code: "timeout",
        provider_error_message: "whatsapp send failed",
        failure_reason: "provider_rejected",
        failed_at: failed_at
      })

    assert failed.status == "failed"
    assert failed.provider_error_code == "timeout"
    assert failed.provider_error_message == "whatsapp send failed"
    assert failed.failure_reason == "provider_rejected"
    assert failed.failed_at == failed_at
    assert is_nil(failed.provider_status)
    assert is_nil(failed.provider_status_at)

    assert {:ok, reviewed} =
             update_attempt(failed, :mark_manual_review, %{
               failure_reason: "contradictory_provider_evidence",
               fallback_channel: "manual_review"
             })

    assert reviewed.status == "manual_review"
  end

  test "stale lifecycle writes fail optimistic locking" do
    attempt = create_queued_attempt!()
    stale = attempt

    assert {:ok, current} =
             update_attempt(attempt, :mark_provider_accepted, %{
               provider_message_id: "wamid.lifecycle-current",
               provider_accepted_at: ~U[2026-07-05 10:20:00Z]
             })

    assert current.lock_version == stale.lock_version + 1

    assert {:error, error} =
             update_attempt(stale, :mark_manual_review, %{
               failure_reason: "stale_write",
               fallback_channel: "manual_review"
             })

    assert inspect(error) =~ "StaleRecord"
  end

  defp provider_accepted_attempt!(provider_message_id \\ nil) do
    attempt = create_queued_attempt!()

    update_attempt(attempt, :mark_provider_accepted, %{
      provider_message_id:
        provider_message_id || "wamid.lifecycle-#{System.unique_integer([:positive])}",
      provider_accepted_at: ~U[2026-07-05 10:04:00Z]
    })
  end

  defp create_queued_attempt! do
    attrs = challenge_attrs!()

    assert {:ok, attempt} =
             DeliveryAttempt
             |> Changeset.for_create(
               :create_queued,
               %{
                 sales_order_id: attrs.sales_order_id,
                 ticket_issue_id: attrs.ticket_issue_id,
                 channel: "whatsapp",
                 provider: "meta",
                 recipient: "+27***4567",
                 attempt_number: 1,
                 correlation_id: "corr-lifecycle-#{System.unique_integer([:positive])}"
               },
               actor: system_actor()
             )
             |> Ash.create(authorize?: false)

    attempt
  end

  defp update_attempt(attempt, action, attrs) do
    attempt
    |> Changeset.for_update(action, attrs, actor: system_actor())
    |> Ash.update(authorize?: false)
  end

  defp system_actor, do: %{actor_type: :system, actor_id: "delivery-attempt-test"}
end
