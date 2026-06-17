defmodule FastCheck.Payments.Paystack.Error do
  @moduledoc """
  Normalized safe error shape for Paystack provider-boundary operations.
  """

  @enforce_keys [:type, :message]
  defstruct [:type, :message, retryable?: false, safe_metadata: %{}]

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t(),
          retryable?: boolean(),
          safe_metadata: map()
        }

  @default_sensitive_message "paystack request failed"

  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.update(:message, "", &sanitize_message/1)

    struct(__MODULE__, attrs)
  end

  @spec sanitize_message(String.t()) :: String.t()
  def sanitize_message(message) when is_binary(message) do
    if sensitive_message?(message), do: @default_sensitive_message, else: message
  end

  def sanitize_message(_), do: @default_sensitive_message

  defp sensitive_message?(message) do
    lower = String.downcase(message)

    String.contains?(message, "sk_") or
      String.contains?(message, "pk_") or
      String.contains?(lower, "paystack") or
      String.contains?(lower, "authorization_url") or
      String.contains?(lower, "access_code") or
      String.contains?(message, "@") or
      Regex.match?(~r/\+?\d{10,}/, message)
  end
end

defimpl Inspect, for: FastCheck.Payments.Paystack.Error do
  alias FastCheck.Payments.Paystack.Error

  def inspect(%Error{} = error, opts) do
    error
    |> Map.from_struct()
    |> Map.update!(:message, &Error.sanitize_message/1)
    |> Inspect.Map.inspect(opts)
  end
end
