defmodule FastCheck.Payments.Paystack.InitializeResult do
  @moduledoc """
  Safe-inspect result for Paystack transaction initialization.
  """

  defstruct [
    :provider_reference,
    :authorization_url,
    :access_code,
    :status,
    :message,
    :safe_data
  ]

  @type t :: %__MODULE__{
          provider_reference: String.t() | nil,
          authorization_url: String.t() | nil,
          access_code: String.t() | nil,
          status: boolean() | nil,
          message: String.t() | nil,
          safe_data: map()
        }
end

defimpl Inspect, for: FastCheck.Payments.Paystack.InitializeResult do
  @redacted_fields [:authorization_url, :access_code, :safe_data]

  def inspect(result, opts) do
    result
    |> Map.from_struct()
    |> Map.drop(@redacted_fields)
    |> Inspect.Map.inspect(opts)
  end
end
