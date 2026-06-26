defmodule FastCheck.Messaging.WhatsApp.Config do
  @moduledoc """
  Loads and validates Meta WhatsApp outbound provider configuration.
  """

  alias FastCheck.Messaging.WhatsApp.Response
  alias FastCheck.Observability.Redactor

  defstruct [
    :enabled,
    :graph_api_base_url,
    :graph_api_version,
    :phone_number_id,
    :access_token,
    :app_secret,
    :request_timeout_ms,
    :receive_timeout_ms,
    :sandbox_mode
  ]

  @type t :: %__MODULE__{
          enabled: boolean(),
          graph_api_base_url: String.t() | nil,
          graph_api_version: String.t() | nil,
          phone_number_id: String.t() | nil,
          access_token: String.t() | nil,
          app_secret: String.t() | nil,
          request_timeout_ms: pos_integer(),
          receive_timeout_ms: pos_integer(),
          sandbox_mode: boolean()
        }

  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:fastcheck, :whatsapp_enabled, false)
  end

  @spec get() :: t()
  def get do
    %__MODULE__{
      enabled: enabled?(),
      graph_api_base_url: present(Application.get_env(:fastcheck, :whatsapp_graph_api_base_url)),
      graph_api_version: present(Application.get_env(:fastcheck, :whatsapp_graph_api_version)),
      phone_number_id: present(Application.get_env(:fastcheck, :whatsapp_phone_number_id)),
      access_token: present(Application.get_env(:fastcheck, :whatsapp_access_token)),
      app_secret: present(Application.get_env(:fastcheck, :whatsapp_app_secret)),
      request_timeout_ms: Application.get_env(:fastcheck, :whatsapp_request_timeout_ms, 5_000),
      receive_timeout_ms: Application.get_env(:fastcheck, :whatsapp_receive_timeout_ms, 10_000),
      sandbox_mode: Application.get_env(:fastcheck, :whatsapp_sandbox_mode, true)
    }
  end

  @spec validate_for_boot() :: :ok | {:error, Response.t()}
  def validate_for_boot do
    config = get()

    if config.enabled do
      validate_required_config(config)
    else
      :ok
    end
  end

  @spec validate_for_call() :: {:ok, t()} | {:error, Response.t()}
  def validate_for_call do
    config = get()

    with :ok <- validate_enabled(config),
         :ok <- validate_required_config(config) do
      {:ok, config}
    end
  end

  @spec redacted_summary() :: map()
  def redacted_summary do
    get()
    |> Map.from_struct()
    |> Map.update!(:access_token, &redact_secret/1)
    |> Map.update!(:app_secret, &redact_secret/1)
  end

  defp validate_enabled(%__MODULE__{enabled: true}), do: :ok

  defp validate_enabled(_config) do
    {:error, missing_config("whatsapp_enabled", "WhatsApp outbound is disabled")}
  end

  defp validate_required_config(config) do
    with :ok <- require_present(config.graph_api_base_url, "whatsapp_graph_api_base_url"),
         :ok <- require_present(config.graph_api_version, "whatsapp_graph_api_version"),
         :ok <- require_present(config.phone_number_id, "whatsapp_phone_number_id"),
         :ok <- require_present(config.access_token, "whatsapp_access_token"),
         :ok <- require_timeout(config.request_timeout_ms, "whatsapp_request_timeout_ms") do
      require_timeout(config.receive_timeout_ms, "whatsapp_receive_timeout_ms")
    end
  end

  defp require_present(value, _key) when is_binary(value) and value != "", do: :ok
  defp require_present(_value, key), do: {:error, missing_config(key, "missing WhatsApp config")}

  defp require_timeout(timeout_ms, _key) when is_integer(timeout_ms) and timeout_ms > 0, do: :ok

  defp require_timeout(_timeout_ms, key),
    do: {:error, missing_config(key, "invalid WhatsApp timeout")}

  defp missing_config(key, message) do
    %Response{
      provider: :meta,
      status: :missing_config,
      provider_error_code: key,
      provider_error_message: message,
      retryable?: false,
      safe_metadata:
        Redactor.safe_metadata(%{
          provider: :meta,
          error_code: :missing_config,
          reason: key
        })
    }
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  defp redact_secret(nil), do: nil
  defp redact_secret(_), do: Redactor.filtered()
end

defimpl Inspect, for: FastCheck.Messaging.WhatsApp.Config do
  alias FastCheck.Messaging.WhatsApp.Config
  alias FastCheck.Observability.Redactor

  def inspect(%Config{} = config, opts) do
    config
    |> Map.from_struct()
    |> Map.update!(:access_token, &redact_secret/1)
    |> Map.update!(:app_secret, &redact_secret/1)
    |> Inspect.Map.inspect(opts)
  end

  defp redact_secret(nil), do: nil
  defp redact_secret(_), do: Redactor.filtered()
end
