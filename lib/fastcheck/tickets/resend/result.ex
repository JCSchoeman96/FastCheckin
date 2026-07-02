defmodule FastCheck.Tickets.Resend.Result do
  @moduledoc """
  Enumeration-safe result contract for ticket resend eligibility and OTP setup.
  """

  alias FastCheck.Observability.Redactor

  @customer_message "If we find a matching ticket, we will send a verification email."
  @statuses [:accepted, :generic_rejected, :rate_limited]

  @enforce_keys [:public_status, :customer_message, :internal_reason, :safe_metadata]
  defstruct public_status: nil,
            customer_message: @customer_message,
            challenge_public_id: nil,
            internal_reason: nil,
            safe_metadata: %{}

  @type public_status :: :accepted | :generic_rejected | :rate_limited

  @type t :: %__MODULE__{
          public_status: public_status(),
          customer_message: String.t(),
          challenge_public_id: String.t() | nil,
          internal_reason: atom() | nil,
          safe_metadata: map()
        }

  @spec new(public_status(), atom(), keyword()) :: t()
  def new(public_status, internal_reason, opts \\ []) when public_status in @statuses do
    %__MODULE__{
      public_status: public_status,
      customer_message: @customer_message,
      challenge_public_id: Keyword.get(opts, :challenge_public_id),
      internal_reason: internal_reason,
      safe_metadata: Keyword.get(opts, :metadata, %{}) |> Redactor.safe_metadata()
    }
  end

  @spec customer_message() :: String.t()
  def customer_message, do: @customer_message
end

defimpl Inspect, for: FastCheck.Tickets.Resend.Result do
  import Inspect.Algebra

  def inspect(result, opts) do
    safe = %{
      public_status: result.public_status,
      internal_reason: result.internal_reason
    }

    concat(["#FastCheck.Tickets.Resend.Result<", to_doc(safe, opts), ">"])
  end
end
