defmodule FastCheck.Messaging.WhatsApp.ResendDeliveryFlowTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import FastCheck.TicketResendFixtures

  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.ResendDeliveryFlow
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation
  alias FastCheck.Tickets.Resend.Otp
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker

  test "verified challenge enqueues ticket link worker with internal challenge id" do
    conversation = insert_conversation!()
    challenge = verified_challenge!(conversation.id)
    conversation = put_challenge(conversation, challenge.public_id)
    command = command("flow-enqueue")

    assert {:ok, :queued, updates} =
             ResendDeliveryFlow.enqueue_verified_ticket_link(command, conversation)

    assert updates["resend_delivery_status"] == "queued"
    assert updates["resend_delivery_correlation_id"] == command.correlation_id
    assert is_binary(updates["resend_delivery_requested_at"])

    assert Map.keys(updates) |> Enum.sort() ==
             [
               "resend_delivery_correlation_id",
               "resend_delivery_requested_at",
               "resend_delivery_status"
             ]

    refute inspect(updates) =~ challenge.public_id
    refute inspect(updates) =~ to_string(challenge.sales_order_id)
    refute inspect(updates) =~ to_string(challenge.ticket_issue_id)
    refute inspect(updates) =~ "/t/"
    refute inspect(updates) =~ "delivery_token"

    assert_enqueued(
      worker: SendWhatsAppTicketLinkWorker,
      args: %{
        "conversation_id" => conversation.id,
        "sales_order_id" => challenge.sales_order_id,
        "ticket_issue_id" => challenge.ticket_issue_id,
        "ticket_resend_challenge_id" => challenge.id,
        "delivery_reason" => "verified_ticket_resend"
      }
    )
  end

  test "missing or unknown challenge does not enqueue" do
    conversation = insert_conversation!()
    command = command("flow-missing")

    assert {:error, :not_ready} =
             ResendDeliveryFlow.enqueue_verified_ticket_link(command, conversation)

    assert {:error, :not_ready} =
             ResendDeliveryFlow.enqueue_verified_ticket_link(
               command,
               put_challenge(conversation, "missing-public-id")
             )

    refute_enqueued(worker: SendWhatsAppTicketLinkWorker)
  end

  test "non-verified, mismatched, and incomplete challenges do not enqueue" do
    conversation = insert_conversation!()
    other_conversation = insert_conversation!(wa_id: "27820000000", phone_e164: "+27820000000")
    pending = pending_challenge!(conversation.id)
    mismatched = verified_challenge!(other_conversation.id)
    missing_order = verified_challenge!(conversation.id)
    missing_ticket = verified_challenge!(conversation.id)

    Repo.update_all(
      from(c in "sales_ticket_resend_challenges", where: c.id == ^missing_order.id),
      set: [sales_order_id: nil]
    )

    Repo.update_all(
      from(c in "sales_ticket_resend_challenges", where: c.id == ^missing_ticket.id),
      set: [ticket_issue_id: nil]
    )

    command = command("flow-undeliverable")

    for challenge <- [pending, mismatched, missing_order, missing_ticket] do
      assert {:error, :not_deliverable} =
               ResendDeliveryFlow.enqueue_verified_ticket_link(
                 command,
                 put_challenge(conversation, challenge.public_id)
               )
    end

    refute_enqueued(worker: SendWhatsAppTicketLinkWorker)
  end

  test "Oban unique conflict is treated as queued" do
    conversation = insert_conversation!()
    challenge = verified_challenge!(conversation.id)
    conversation = put_challenge(conversation, challenge.public_id)
    command = command("flow-conflict")

    assert {:ok, :queued, first_updates} =
             ResendDeliveryFlow.enqueue_verified_ticket_link(command, conversation)

    assert {:ok, :queued, second_updates} =
             ResendDeliveryFlow.enqueue_verified_ticket_link(command, conversation)

    assert first_updates["resend_delivery_status"] == "queued"
    assert second_updates["resend_delivery_status"] == "queued"
  end

  test "non-unique Oban changeset error is not treated as queued" do
    conversation = insert_conversation!()
    challenge = verified_challenge!(conversation.id)
    conversation = put_challenge(conversation, challenge.public_id)
    command = command("flow-invalid-changeset")

    changeset =
      %Oban.Job{}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:args, "invalid")

    assert {:error, :not_ready} =
             ResendDeliveryFlow.enqueue_verified_ticket_link(command, conversation,
               oban_insert_fun: fn _job -> {:error, changeset} end
             )
  end

  defp pending_challenge!(conversation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, challenge, _otp} =
      Otp.issue(challenge_attrs!(conversation_id: conversation_id), now, return_otp?: true)

    challenge
  end

  defp verified_challenge!(conversation_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, challenge, otp} =
      Otp.issue(challenge_attrs!(conversation_id: conversation_id), now, return_otp?: true)

    {:ok, verified} = Otp.verify(challenge.public_id, otp, DateTime.add(now, 1, :second))
    verified
  end

  defp put_challenge(%Conversation{} = conversation, public_id) do
    %{
      conversation
      | state_data:
          Map.merge(conversation.state_data || %{}, %{
            "resend_challenge_public_id" => public_id,
            "resend_otp_verification_status" => "verified"
          })
    }
  end

  defp command(suffix) do
    %MessageCommand{
      provider: "meta",
      provider_message_id: "wamid.#{suffix}",
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      message_type: "text",
      text_body: "hello",
      received_at: DateTime.utc_now() |> DateTime.truncate(:second),
      raw_payload_hash: "hash-#{suffix}",
      correlation_id: "corr-#{suffix}",
      metadata: %{}
    }
  end

  defp insert_conversation!(opts \\ []) do
    phone_e164 = Keyword.get(opts, :phone_e164, "+27821234567")
    wa_id = Keyword.get(opts, :wa_id, "27821234567")

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES
          ($1, $2, 'af', 'awaiting_verified_resend_delivery', '{}', false, now(), now())
        RETURNING id
        """,
        [phone_e164, wa_id]
      )

    Repo.get!(Conversation, id)
  end
end
