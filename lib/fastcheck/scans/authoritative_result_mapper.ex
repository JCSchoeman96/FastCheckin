defmodule FastCheck.Scans.AuthoritativeResultMapper do
  @moduledoc """
  Maps authoritative scan results to the stable mobile API item shape.

  Only publish additive reason codes when the authoritative path can prove the
  outcome without inferring from human-readable messages.
  """

  alias FastCheck.Scans.Result

  @type api_result :: %{
          required(:idempotency_key) => String.t(),
          required(:status) => String.t(),
          required(:message) => String.t(),
          optional(:reason_code) => String.t()
        }

  @spec to_api_result(Result.t()) :: api_result()
  def to_api_result(%Result{delivery_state: :final_acknowledged} = result) do
    %{
      idempotency_key: result.idempotency_key,
      status: "duplicate",
      message: duplicate_message(result),
      reason_code: "replay_duplicate"
    }
  end

  def to_api_result(%Result{status: "error", reason_code: "DUPLICATE"} = result) do
    %{
      idempotency_key: result.idempotency_key,
      status: "error",
      message: result.message,
      reason_code: "business_duplicate"
    }
  end

  def to_api_result(%Result{status: "error", reason_code: "PAYMENT_INVALID"} = result) do
    %{
      idempotency_key: result.idempotency_key,
      status: "error",
      message: result.message,
      reason_code: "payment_invalid"
    }
  end

  def to_api_result(%Result{} = result) do
    %{
      idempotency_key: result.idempotency_key,
      status: result.status,
      message: result.message
    }
  end

  defp duplicate_message(%Result{message: message}) when is_binary(message) and message != "" do
    "Already processed: #{message}"
  end

  defp duplicate_message(_result), do: "Already processed"
end
