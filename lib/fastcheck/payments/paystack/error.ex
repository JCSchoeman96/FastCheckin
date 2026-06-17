defmodule FastCheck.Payments.Paystack.Error do
  @moduledoc """
  Safe normalized error shape for Paystack provider-boundary operations.
  """

  @enforce_keys [:type, :message]
  defstruct [:type, :message, retryable?: false, safe_metadata: %{}]

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t(),
          retryable?: boolean(),
          safe_metadata: map()
        }
end
