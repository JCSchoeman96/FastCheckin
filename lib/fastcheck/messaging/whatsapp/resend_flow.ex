defmodule FastCheck.Messaging.WhatsApp.ResendFlow do
  @moduledoc """
  WhatsApp resend identity collection orchestration for VS-24D-C.
  """

  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Sales.Conversation
  alias FastCheck.Tickets.Resend.EmailOtp
  alias FastCheck.Tickets.Resend.Request
  alias FastCheck.Tickets.Resend.Result

  @spec normalize_name(term()) :: {:ok, String.t()} | {:error, :invalid_name}
  defdelegate normalize_name(name), to: Request

  @spec normalize_email(term()) :: {:ok, String.t()} | {:error, :invalid_email}
  defdelegate normalize_email(email), to: Request

  @spec request_email_otp(MessageCommand.t(), Conversation.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def request_email_otp(%MessageCommand{} = command, %Conversation{} = conversation, opts \\ []) do
    state_data = Keyword.get(opts, :state_data, state_data(conversation))
    email_otp_fun = Keyword.get(opts, :email_otp_fun, &EmailOtp.request_email_otp/2)

    request = %Request{
      name: Map.get(state_data, "resend_name"),
      email: Map.get(state_data, "resend_email"),
      source: %{
        conversation_id: conversation.id,
        phone_e164: command.phone_e164,
        wa_id: command.wa_id
      },
      correlation_id: command.correlation_id,
      idempotency_key: command.provider_message_id,
      now: command.received_at
    }

    with {:ok, %Result{} = result} <- email_otp_fun.(request, []) do
      {:ok, result_updates(result, command)}
    end
  end

  defp result_updates(%Result{} = result, %MessageCommand{} = command) do
    %{
      "resend_requested_at" => DateTime.to_iso8601(command.received_at),
      "resend_email_otp_result_status" => Atom.to_string(result.public_status),
      "resend_correlation_id" => command.correlation_id
    }
    |> maybe_put_challenge_public_id(result)
  end

  defp maybe_put_challenge_public_id(updates, %Result{
         public_status: :accepted,
         challenge_public_id: challenge_public_id
       })
       when is_binary(challenge_public_id) and challenge_public_id != "" do
    Map.put(updates, "resend_challenge_public_id", challenge_public_id)
  end

  defp maybe_put_challenge_public_id(updates, _result), do: updates

  defp state_data(%Conversation{state_data: data}) when is_map(data), do: data
  defp state_data(_conversation), do: %{}
end
