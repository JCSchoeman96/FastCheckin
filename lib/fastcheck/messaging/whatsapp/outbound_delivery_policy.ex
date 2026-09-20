defmodule FastCheck.Messaging.WhatsApp.OutboundDeliveryPolicy do
  @moduledoc """
  Classifies WhatsApp outbound delivery outcomes for safe retry vs manual review.

  Determines whether a provider response represents a business operation that is
  safe to repeat (:safe_retry) or requires manual intervention (:ambiguous_manual_review
  or :permanent_manual_review).
  """

  alias FastCheck.Messaging.WhatsApp.Response

  @type decision ::
          :safe_retry
          | :ambiguous_manual_review
          | :permanent_manual_review

  @doc """
  Classify a normalized Client.Response or error into an outbound delivery policy decision.

  ## Examples

      iex> %Response{status: :rate_limited, retryable?: true}
      |> OutboundDeliveryPolicy.classify()
      :safe_retry

      iex> %Response{status: :timeout, retryable?: true}
      |> OutboundDeliveryPolicy.classify()
      :ambiguous_manual_review

      iex> %Response{status: :validation_error, retryable?: false}
      |> OutboundDeliveryPolicy.classify()
      :permanent_manual_review
  """
  @spec classify(Response.t() | {:error, any()} | any()) :: decision
  def classify(%Response{} = response) do
    cond do
      safe_retry?(response) -> :safe_retry
      permanent_manual_review?(response) -> :permanent_manual_review
      true -> :ambiguous_manual_review
    end
  end

  def classify({:error, %Response{} = response}), do: classify(response)
  def classify({:error, _reason}), do: :ambiguous_manual_review
  def classify(_other), do: :ambiguous_manual_review

  defp safe_retry?(%Response{} = response) do
    response.status == :rate_limited or response.raw_status == 429
  end

  defp permanent_manual_review?(%Response{} = response) do
    response.status in [:validation_error, :auth_error, :missing_config] or
      known_non_retryable_4xx?(response)
  end

  defp known_non_retryable_4xx?(%Response{} = response) do
    is_integer(response.raw_status) and
      response.raw_status in 400..499 and
      response.retryable? == false
  end
end
