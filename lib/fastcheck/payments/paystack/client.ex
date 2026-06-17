defmodule FastCheck.Payments.Paystack.Client do
  @moduledoc """
  Low-level HTTP client for Paystack provider-boundary calls.
  """

  require Logger

  alias FastCheck.Observability.Correlation
  alias FastCheck.Observability.Redactor
  alias FastCheck.Payments.Paystack.Config
  alias FastCheck.Payments.Paystack.Error
  alias FastCheck.Payments.Paystack.ResponseSanitizer
  alias Req.Response
  alias Req.TransportError

  @request_fun Application.compile_env(:fastcheck, :paystack_request_fun, &Req.request/1)

  @spec request(atom(), String.t(), map() | keyword() | nil, keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request(method, path, payload \\ nil, opts \\ []) when method in [:get, :post] do
    with {:ok, config} <- Config.validate_for_call() do
      correlation_id = correlation_id(opts)
      started_at = System.monotonic_time(:millisecond)
      request_fun = Application.get_env(:fastcheck, :paystack_request_fun, @request_fun)

      req =
        Req.new(
          method: method,
          url: build_url(config.base_url, path),
          decode_body: false,
          receive_timeout: config.timeout_ms,
          headers: [
            {"authorization", "Bearer #{config.secret_key}"},
            {"accept", "application/json"},
            {"content-type", "application/json"}
          ],
          json: if(method == :post, do: payload || %{}, else: nil),
          params: if(method == :get, do: payload || [], else: [])
        )

      case request_fun.(req) do
        {:ok, %Response{} = response} ->
          duration_ms = System.monotonic_time(:millisecond) - started_at
          normalize_response(response, correlation_id, duration_ms)

        {:error, %TransportError{reason: :timeout}} ->
          {:error, transport_error(:timeout, correlation_id, true)}

        {:error, %TransportError{} = transport_error} ->
          {:error, transport_error(transport_error.reason, correlation_id, true)}

        {:error, reason} ->
          {:error, transport_error(reason, correlation_id, true)}
      end
    end
  end

  @spec post(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def post(path, payload, opts \\ []), do: request(:post, path, payload, opts)

  @spec get(String.t(), keyword(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(path, query_params \\ [], opts \\ []), do: request(:get, path, query_params, opts)

  defp normalize_response(%Response{status: status, body: body}, correlation_id, duration_ms) do
    case decode_json(body) do
      {:ok, decoded} ->
        if status in 200..299 do
          case decoded do
            %{"status" => true} ->
              {:ok, decoded}

            %{"status" => false} ->
              {:error,
               provider_error(
                 :provider_error,
                 status,
                 decoded,
                 correlation_id,
                 false,
                 duration_ms
               )}

            _ ->
              {:ok, decoded}
          end
        else
          {:error, error_from_status(status, decoded, correlation_id, duration_ms)}
        end

      {:error, _} ->
        {:error,
         %Error{
           type: :decode_error,
           message: "unable to decode Paystack response body",
           retryable?: false,
           safe_metadata: %{
             provider: :paystack,
             correlation_id: correlation_id,
             http_status: status
           }
         }}
    end
  end

  defp error_from_status(status, decoded, correlation_id, duration_ms) do
    {type, retryable?} =
      cond do
        status == 400 -> {:invalid_request, false}
        status == 401 -> {:unauthorized, false}
        status == 403 -> {:forbidden, false}
        status == 404 -> {:not_found, false}
        status == 429 -> {:rate_limited, true}
        status >= 500 -> {:provider_error, true}
        true -> {:unknown_error, false}
      end

    provider_error(type, status, decoded, correlation_id, retryable?, duration_ms)
  end

  defp provider_error(type, status, decoded, correlation_id, retryable?, duration_ms) do
    message =
      decoded
      |> extract_provider_message()
      |> case do
        nil -> "paystack request failed"
        msg -> msg
      end

    safe_metadata =
      %{
        provider: :paystack,
        correlation_id: correlation_id,
        http_status: status,
        retryable?: retryable?,
        duration_ms: duration_ms,
        provider_response: ResponseSanitizer.sanitize(decoded)
      }
      |> Redactor.safe_metadata()

    Logger.warning(
      "Paystack request failed",
      Correlation.operational_metadata(%{
        provider: :paystack,
        correlation_id: correlation_id,
        duration_ms: duration_ms,
        error_code: type
      })
    )

    %Error{type: type, message: message, retryable?: retryable?, safe_metadata: safe_metadata}
  end

  defp transport_error(reason, correlation_id, retryable?) do
    type = if(reason == :timeout, do: :timeout, else: :provider_unavailable)

    %Error{
      type: type,
      message: "paystack request transport failure",
      retryable?: retryable?,
      safe_metadata:
        Redactor.safe_metadata(%{
          provider: :paystack,
          reason: inspect(reason),
          correlation_id: correlation_id
        })
    }
  end

  defp extract_provider_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp extract_provider_message(%{message: msg}) when is_binary(msg), do: msg
  defp extract_provider_message(_), do: nil

  defp decode_json(body) when is_binary(body), do: Jason.decode(body)
  defp decode_json(body) when is_map(body), do: {:ok, body}
  defp decode_json(_), do: {:error, :invalid_body}

  defp build_url(base_url, path) do
    base = String.trim_trailing(base_url, "/")
    suffix = String.trim_leading(path, "/")
    base <> "/" <> suffix
  end

  defp correlation_id(opts) do
    opts
    |> Enum.into(%{})
    |> Correlation.ensure_correlation_id()
  end
end
