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

  defp system_actor, do: %{actor_type: :system, actor_id: "delivery-attempt-test"}
end
