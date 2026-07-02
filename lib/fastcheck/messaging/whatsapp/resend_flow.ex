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

  @spec verify_email_otp(MessageCommand.t(), Conversation.t(), keyword()) ::
          {:ok, :verified, map()}
          | {:error, :invalid_or_expired | :locked | :already_verified}
  def verify_email_otp(%MessageCommand{} = command, %Conversation{} = conversation, opts \\ []) do
    state_data = Keyword.get(opts, :state_data, state_data(conversation))
    verify_otp_fun = Keyword.get(opts, :verify_otp_fun, &EmailOtp.verify_otp/3)

    with {:ok, challenge_public_id} <- challenge_public_id(state_data),
         {:ok, submitted_otp} <- submitted_otp(command),
         {:ok, _challenge} <-
           verify_otp_fun.(challenge_public_id, submitted_otp, now: command.received_at) do
      {:ok, :verified, verification_updates(command)}
    else
      {:error, :invalid_or_expired} -> {:error, :invalid_or_expired}
      {:error, :locked} -> {:error, :locked}
      {:error, :already_verified} -> {:error, :already_verified}
      {:error, _reason} -> {:error, :invalid_or_expired}
      _other -> {:error, :invalid_or_expired}
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

  defp challenge_public_id(state_data) do
    case Map.get(state_data, "resend_challenge_public_id") do
      challenge_public_id when is_binary(challenge_public_id) ->
        challenge_public_id
        |> String.trim()
        |> case do
          "" -> {:error, :invalid_or_expired}
          value -> {:ok, value}
        end

      _other ->
        {:error, :invalid_or_expired}
    end
  end

  defp submitted_otp(%MessageCommand{text_body: text_body}) do
    submitted_otp =
      (text_body || "")
      |> to_string()
      |> String.trim()

    if Regex.match?(~r/^\d+$/, submitted_otp) do
      {:ok, submitted_otp}
    else
      {:error, :invalid_or_expired}
    end
  end

  defp verification_updates(%MessageCommand{} = command) do
    %{
      "resend_otp_verified_at" => DateTime.to_iso8601(command.received_at),
      "resend_otp_verification_status" => "verified"
    }
  end

  defp state_data(%Conversation{state_data: data}) when is_map(data), do: data
  defp state_data(_conversation), do: %{}
end
