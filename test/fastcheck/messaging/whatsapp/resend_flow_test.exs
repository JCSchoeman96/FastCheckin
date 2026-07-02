defmodule FastCheck.Messaging.WhatsApp.ResendFlowTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.ResendFlow
  alias FastCheck.Sales.Conversation
  alias FastCheck.Tickets.Resend.Result

  test "builds email OTP request from normalized resend state and accepted result keeps private challenge id" do
    command = command()

    conversation =
      conversation(%{"resend_name" => "jamie smith", "resend_email" => "jamie@example.com"})

    challenge_public_id = "challenge-public-test"

    email_otp_fun = fn request, _opts ->
      assert request.name == "jamie smith"
      assert request.email == "jamie@example.com"

      assert request.source == %{
               conversation_id: conversation.id,
               phone_e164: command.phone_e164,
               wa_id: command.wa_id
             }

      assert request.correlation_id == command.correlation_id
      assert request.idempotency_key == command.provider_message_id
      assert request.now == command.received_at

      {:ok,
       Result.new(:accepted, :otp_challenge_created, challenge_public_id: challenge_public_id)}
    end

    assert {:ok, updates} =
             ResendFlow.request_email_otp(command, conversation, email_otp_fun: email_otp_fun)

    assert updates["resend_email_otp_result_status"] == "accepted"
    assert updates["resend_correlation_id"] == command.correlation_id
    assert updates["resend_requested_at"] == DateTime.to_iso8601(command.received_at)
    assert updates["resend_challenge_public_id"] == challenge_public_id
  end

  test "does not keep challenge id for rejected or rate-limited results" do
    for status <- [:generic_rejected, :rate_limited] do
      email_otp_fun = fn _request, _opts -> {:ok, Result.new(status, :rate_limited)} end

      assert {:ok, updates} =
               ResendFlow.request_email_otp(
                 command(),
                 conversation(%{
                   "resend_name" => "jamie smith",
                   "resend_email" => "jamie@example.com"
                 }),
                 email_otp_fun: email_otp_fun
               )

      assert updates["resend_email_otp_result_status"] == Atom.to_string(status)
      refute Map.has_key?(updates, "resend_challenge_public_id")
    end
  end

  defp command do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %MessageCommand{
      provider: "meta",
      provider_message_id: "wamid.resend-flow",
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      message_type: "text",
      text_body: "jamie@example.com",
      received_at: now,
      raw_payload_hash: "hash-resend-flow",
      correlation_id: "corr-resend-flow",
      metadata: %{}
    }
  end

  defp conversation(state_data) do
    %Conversation{
      id: 123,
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      preferred_language: "en",
      state: "collecting_resend_email",
      state_data: state_data,
      needs_human: false
    }
  end
end
