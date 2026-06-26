defmodule FastCheck.Messaging.WhatsApp.Client do
  @moduledoc """
  Stateless outbound client for Meta WhatsApp Cloud API messages.
  """

  require Logger

  alias FastCheck.Messaging.WhatsApp.Config
  alias FastCheck.Messaging.WhatsApp.MessageBuilder
  alias FastCheck.Messaging.WhatsApp.Response
  alias FastCheck.Observability.Correlation
  alias FastCheck.Observability.Redactor
  alias Req.TransportError

  @spec send_text(String.t(), String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, Response.t()}
  def send_text(to_e164, body, opts \\ []) do
    with {:ok, payload} <- MessageBuilder.text_message(to_e164, body) do
      send_payload(:send_text, :text, payload, opts)
    end
  end

  @spec send_template(String.t(), atom(), String.t(), list(), keyword()) ::
          {:ok, Response.t()} | {:error, Response.t()}
  def send_template(to_e164, template_name, language_code, components \\ [], opts \\ []) do
    with {:ok, payload} <-
           MessageBuilder.template_message(to_e164, template_name, language_code, components) do
      send_payload(:send_template, :template, payload, opts)
    end
  end

  defp send_payload(operation, message_type, payload, opts) do
    with {:ok, config} <- Config.validate_for_call() do
      correlation_id = correlation_id(opts)
      started_at = System.monotonic_time(:millisecond)
      request_fun = Application.get_env(:fastcheck, :whatsapp_request_fun, &Req.request/1)

      req =
        Req.new(
          method: :post,
          url: build_url(config),
          decode_body: false,
          connect_options: [timeout: config.request_timeout_ms],
          receive_timeout: config.receive_timeout_ms,
          headers: [
            {"authorization", "Bearer #{config.access_token}"},
            {"accept", "application/json"},
            {"content-type", "application/json"}
          ],
          json: payload
        )

      result =
        try do
          request_fun.(req)
        rescue
          exception ->
            {:error, exception}
        catch
          kind, reason ->
            {:error, {kind, reason}}
        end

      duration_ms = System.monotonic_time(:millisecond) - started_at
      normalize_result(result, operation, message_type, correlation_id, duration_ms)
    end
  end

  defp normalize_result(
         {:ok, %Req.Response{status: status, body: body}},
         operation,
         message_type,
         id,
         duration_ms
       ) do
    response =
      case decode_body(body) do
        {:ok, decoded_body} ->
          if status in 200..299 do
            accepted_response(status, decoded_body, operation, message_type, id, duration_ms)
          else
            {:error,
             error_from_status(status, decoded_body, operation, message_type, id, duration_ms)}
          end

        {:error, _reason} ->
          {:error, decode_error_response(status, operation, message_type, id, duration_ms)}
      end

    log_result(response, operation, message_type)
    response
  end

  defp normalize_result(
         {:error, %TransportError{reason: :timeout}},
         operation,
         message_type,
         id,
         duration_ms
       ) do
    response =
      {:error, transport_response(:timeout, :timeout, operation, message_type, id, duration_ms)}

    log_result(response, operation, message_type)
    response
  end

  defp normalize_result(
         {:error, %TransportError{} = error},
         operation,
         message_type,
         id,
         duration_ms
       ) do
    response =
      {:error,
       transport_response(
         :transport_error,
         error.reason,
         operation,
         message_type,
         id,
         duration_ms
       )}

    log_result(response, operation, message_type)
    response
  end

  defp normalize_result({:error, reason}, operation, message_type, id, duration_ms) do
    response =
      {:error,
       transport_response(:transport_error, reason, operation, message_type, id, duration_ms)}

    log_result(response, operation, message_type)
    response
  end

  defp accepted_response(status, body, operation, message_type, correlation_id, duration_ms) do
    case provider_message_id(body) do
      id when is_binary(id) and id != "" ->
        {:ok,
         %Response{
           provider: :meta,
           provider_message_id: id,
           status: :accepted,
           raw_status: status,
           provider_status: "accepted",
           retryable?: false,
           rate_limited?: false,
           safe_metadata:
             metadata(
               operation,
               message_type,
               :accepted,
               status,
               false,
               correlation_id,
               duration_ms
             )
         }}

      _ ->
        {:error,
         %Response{
           provider: :meta,
           status: :unknown_error,
           raw_status: status,
           provider_error_message: "meta response did not include message id",
           retryable?: false,
           safe_metadata:
             metadata(
               operation,
               message_type,
               :unknown_error,
               status,
               false,
               correlation_id,
               duration_ms
             )
         }}
    end
  end

  defp error_from_status(status, body, operation, message_type, correlation_id, duration_ms) do
    {response_status, retryable?, rate_limited?} =
      cond do
        status == 400 -> {:validation_error, false, false}
        status in [401, 403] -> {:auth_error, false, false}
        status == 429 -> {:rate_limited, true, true}
        status >= 500 -> {:server_error, true, false}
        true -> {:unknown_error, false, false}
      end

    %Response{
      provider: :meta,
      status: response_status,
      raw_status: status,
      provider_error_code: provider_error_code(body),
      provider_error_message: provider_error_message(body),
      retryable?: retryable?,
      rate_limited?: rate_limited?,
      safe_metadata:
        metadata(
          operation,
          message_type,
          response_status,
          status,
          retryable?,
          correlation_id,
          duration_ms
        )
    }
  end

  defp transport_response(status, reason, operation, message_type, correlation_id, duration_ms) do
    %Response{
      provider: :meta,
      status: status,
      provider_error_code: Atom.to_string(status),
      provider_error_message: "meta request transport failure",
      retryable?: true,
      rate_limited?: false,
      safe_metadata:
        metadata(operation, message_type, status, nil, true, correlation_id, duration_ms)
        |> Map.put(:reason, safe_transport_reason(reason))
        |> Redactor.safe_metadata()
    }
  end

  defp decode_error_response(status, operation, message_type, correlation_id, duration_ms) do
    %Response{
      provider: :meta,
      status: :unknown_error,
      raw_status: status,
      provider_error_code: "decode_error",
      provider_error_message: "meta response could not be decoded",
      retryable?: status >= 500,
      rate_limited?: false,
      safe_metadata:
        metadata(
          operation,
          message_type,
          :unknown_error,
          status,
          status >= 500,
          correlation_id,
          duration_ms
        )
    }
  end

  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(_body), do: {:error, :invalid_body}

  defp safe_transport_reason(:timeout), do: "timeout"
  defp safe_transport_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_transport_reason(%module{}) when is_atom(module), do: "exception"
  defp safe_transport_reason(_reason), do: "transport_failure"

  defp provider_message_id(%{"messages" => [%{"id" => id} | _]}), do: id
  defp provider_message_id(%{messages: [%{id: id} | _]}), do: id
  defp provider_message_id(_), do: nil

  defp provider_error_code(%{"error" => %{"code" => code}}), do: to_string(code)
  defp provider_error_code(%{error: %{code: code}}), do: to_string(code)
  defp provider_error_code(_), do: nil

  defp provider_error_message(%{"error" => %{"message" => message}}) when is_binary(message) do
    sanitize_provider_message(message)
  end

  defp provider_error_message(%{error: %{message: message}}) when is_binary(message) do
    sanitize_provider_message(message)
  end

  defp provider_error_message(_), do: "meta request failed"

  defp sanitize_provider_message(message) do
    cond do
      String.contains?(message, "EAAG") ->
        "meta request failed"

      String.contains?(message, "http://") or String.contains?(message, "https://") ->
        "meta request failed"

      Regex.match?(~r/\+?\d{8,}/, message) ->
        "meta request failed"

      String.contains?(String.downcase(message), "token") ->
        "meta request failed"

      true ->
        message
    end
  end

  defp log_result({:ok, %Response{} = response}, operation, message_type) do
    Logger.info(
      "WhatsApp outbound request accepted",
      log_metadata(response, operation, message_type)
    )
  end

  defp log_result({:error, %Response{} = response}, operation, message_type) do
    Logger.warning(
      "WhatsApp outbound request failed",
      log_metadata(response, operation, message_type)
    )
  end

  defp log_metadata(response, operation, message_type) do
    Correlation.operational_metadata(%{
      provider: :meta,
      source: Atom.to_string(operation),
      status: response.status,
      error_code: response.provider_error_code,
      duration_ms: Map.get(response.safe_metadata, :duration_ms),
      result: Atom.to_string(message_type),
      correlation_id: Map.get(response.safe_metadata, :correlation_id)
    })
  end

  defp metadata(
         operation,
         message_type,
         status,
         http_status,
         retryable?,
         correlation_id,
         duration_ms
       ) do
    %{
      provider: :meta,
      source: Atom.to_string(operation),
      result: Atom.to_string(message_type),
      status: status,
      http_status: http_status,
      retryable?: retryable?,
      correlation_id: correlation_id,
      duration_ms: duration_ms
    }
    |> Redactor.safe_metadata()
  end

  defp build_url(config) do
    base = String.trim_trailing(config.graph_api_base_url, "/")
    version = String.trim(config.graph_api_version, "/")
    phone_number_id = String.trim(config.phone_number_id, "/")

    base <> "/" <> version <> "/" <> phone_number_id <> "/messages"
  end

  defp correlation_id(opts) do
    opts
    |> Enum.into(%{})
    |> Correlation.ensure_correlation_id()
  end
end
