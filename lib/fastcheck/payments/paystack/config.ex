defmodule FastCheck.Payments.Paystack.Config do
  @moduledoc """
  Loads and validates Paystack provider-boundary configuration.
  """

  alias FastCheck.Payments.Paystack.Error

  @known_channels MapSet.new([
                    "card",
                    "bank",
                    "apple_pay",
                    "ussd",
                    "qr",
                    "mobile_money",
                    "bank_transfer",
                    "eft",
                    "capitec_pay",
                    "payattitude"
                  ])

  @reference_regex ~r/^[A-Za-z0-9.\-=]+$/

  @type t :: %{
          enabled: boolean(),
          environment: String.t(),
          base_url: String.t(),
          public_key: String.t() | nil,
          secret_key: String.t() | nil,
          timeout_ms: pos_integer(),
          allowed_channels: [String.t()],
          callback_url: String.t() | nil,
          webhook_url: String.t() | nil
        }

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:fastcheck, :paystack_enabled, false)

  @spec get() :: t()
  def get do
    %{
      enabled: enabled?(),
      environment: Application.get_env(:fastcheck, :paystack_environment, "test"),
      base_url: Application.get_env(:fastcheck, :paystack_base_url, "https://api.paystack.co"),
      public_key: present(Application.get_env(:fastcheck, :paystack_public_key)),
      secret_key: present(Application.get_env(:fastcheck, :paystack_secret_key)),
      timeout_ms: Application.get_env(:fastcheck, :paystack_timeout_ms, 10_000),
      allowed_channels:
        parse_allowed_channels(Application.get_env(:fastcheck, :paystack_allowed_channels, [])),
      callback_url: present(Application.get_env(:fastcheck, :paystack_callback_url)),
      webhook_url: present(Application.get_env(:fastcheck, :paystack_webhook_url))
    }
  end

  @spec validate_for_boot() :: :ok | {:error, Error.t()}
  def validate_for_boot do
    config = get()
    if config.enabled, do: validate_required_config(config), else: :ok
  end

  @spec validate_for_call() :: {:ok, t()} | {:error, Error.t()}
  def validate_for_call do
    config = get()

    with :ok <- validate_enabled(config),
         :ok <- validate_required_config(config) do
      {:ok, config}
    end
  end

  @spec normalize_reference(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def normalize_reference(reference) when is_binary(reference) do
    trimmed = String.trim(reference)

    cond do
      trimmed == "" ->
        {:error, invalid_reference_error("reference is required")}

      String.length(trimmed) > 100 ->
        {:error, invalid_reference_error("reference is too long")}

      not Regex.match?(@reference_regex, trimmed) ->
        {:error, invalid_reference_error("reference contains unsupported characters")}

      true ->
        {:ok, trimmed}
    end
  end

  def normalize_reference(_), do: {:error, invalid_reference_error("reference must be a string")}

  @spec valid_reference?(term()) :: boolean()
  def valid_reference?(reference), do: match?({:ok, _}, normalize_reference(reference))

  @spec known_channels() :: [String.t()]
  def known_channels, do: @known_channels |> MapSet.to_list() |> Enum.sort()

  @spec parse_allowed_channels(term()) :: [String.t()]
  def parse_allowed_channels(channels) when is_binary(channels) do
    channels
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_allowed_channels(channels) when is_list(channels) do
    channels
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_allowed_channels(_), do: []

  defp validate_enabled(%{enabled: true}), do: :ok

  defp validate_enabled(_) do
    {:error,
     %Error{
       type: :missing_config,
       message: "Paystack is disabled",
       safe_metadata: %{provider: :paystack, reason: :disabled}
     }}
  end

  defp validate_required_config(config) do
    with :ok <- require_present(config.secret_key, :paystack_secret_key),
         :ok <- require_present(config.public_key, :paystack_public_key),
         :ok <- require_present(config.base_url, :paystack_base_url),
         :ok <- require_timeout(config.timeout_ms),
         :ok <- validate_channels(config.allowed_channels) do
      :ok
    end
  end

  defp validate_channels(channels) do
    invalid = Enum.reject(channels, &MapSet.member?(@known_channels, &1))

    if invalid == [] do
      :ok
    else
      {:error,
       %Error{
         type: :invalid_request,
         message: "PAYSTACK_ALLOWED_CHANNELS contains unsupported values",
         safe_metadata: %{provider: :paystack, invalid_channels: invalid}
       }}
    end
  end

  defp require_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0, do: :ok

  defp require_timeout(_) do
    {:error,
     %Error{
       type: :missing_config,
       message: "paystack_timeout_ms must be a positive integer",
       safe_metadata: %{provider: :paystack, key: :paystack_timeout_ms}
     }}
  end

  defp require_present(value, _key) when is_binary(value) and value != "", do: :ok

  defp require_present(_, key) do
    {:error,
     %Error{
       type: :missing_config,
       message: "missing required Paystack config",
       safe_metadata: %{provider: :paystack, key: key}
     }}
  end

  defp invalid_reference_error(message) do
    %Error{
      type: :invalid_request,
      message: message,
      safe_metadata: %{provider: :paystack, field: :reference}
    }
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil
end
