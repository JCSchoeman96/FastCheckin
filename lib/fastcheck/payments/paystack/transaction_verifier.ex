defmodule FastCheck.Payments.Paystack.TransactionVerifier do
  @moduledoc """
  Provider-boundary API for Paystack transaction verification by reference.
  """

  alias FastCheck.Payments.Paystack.Client
  alias FastCheck.Payments.Paystack.Config
  alias FastCheck.Payments.Paystack.Error
  alias FastCheck.Payments.Paystack.ResponseSanitizer

  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def verify(reference, opts \\ []) do
    with {:ok, normalized_reference} <- Config.normalize_reference(reference),
         {:ok, response} <- Client.get("/transaction/verify/#{normalized_reference}", [], opts) do
      {:ok, normalize_verify_response(response)}
    end
  end

  defp normalize_verify_response(response) do
    data = response["data"] || %{}

    %{
      provider_reference: data["reference"],
      provider_status: data["status"],
      amount: data["amount"],
      currency: data["currency"],
      paid_at: data["paid_at"],
      gateway_response: data["gateway_response"],
      status: response["status"],
      message: response["message"],
      safe_data: ResponseSanitizer.drop_sensitive(data)
    }
  end
end
