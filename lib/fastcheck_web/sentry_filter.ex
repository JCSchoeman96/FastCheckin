defmodule FastCheckWeb.SentryFilter do
  @moduledoc """
  Sentry event filter to sanitize sensitive data before sending to Sentry.

  Recursively redacts Sales-sensitive fields (PII, tokens, provider payloads,
  payment URLs) from request data, headers, query params, and extra metadata.
  Delegates map/list redaction to `FastCheck.Observability.Redactor`.
  """

  @behaviour Sentry.EventFilter

  alias FastCheck.Observability.Redactor

  @impl true
  def exclude_exception?(_exception, _source), do: false

  def filter_event(event) do
    event
    |> filter_request_data()
    |> filter_extra_data()
  end

  defp filter_request_data(%{request: request} = event) when is_map(request) do
    filtered_request =
      request
      |> Map.update(:data, %{}, &redact_structure/1)
      |> Map.update(:headers, %{}, &redact_headers/1)
      |> Map.update(:query_string, nil, &redact_query_string/1)
      |> Map.update(:query, %{}, &redact_structure/1)
      |> Map.update(:url, nil, &redact_url_field/1)

    %{event | request: filtered_request}
  end

  defp filter_request_data(event), do: event

  defp filter_extra_data(%{extra: extra} = event) when is_map(extra) do
    %{event | extra: redact_structure(extra)}
  end

  defp filter_extra_data(event), do: event

  defp redact_structure(data) when is_map(data) do
    Redactor.redact_map(data, preserve_safe_ids: true)
  end

  defp redact_structure(data) when is_list(data) do
    Redactor.redact_value(:list, data, preserve_safe_ids: true)
  end

  defp redact_structure(data), do: data

  defp redact_headers(headers) when is_map(headers) do
    Enum.into(headers, %{}, fn {key, value} ->
      normalized = String.downcase(to_string(key))

      if sensitive_header?(normalized) do
        {key, Redactor.filtered()}
      else
        {key, value}
      end
    end)
  end

  defp redact_headers(headers), do: headers

  defp sensitive_header?(normalized) do
    String.contains?(normalized, [
      "authorization",
      "cookie",
      "token",
      "signature",
      "secret"
    ])
  end

  defp redact_query_string(nil), do: nil

  defp redact_query_string(query_string) when is_binary(query_string) do
    Redactor.redact_url("http://localhost/?" <> query_string)
    |> String.replace_prefix("http://localhost/", "")
  end

  defp redact_query_string(_), do: Redactor.filtered()

  defp redact_url_field(nil), do: nil
  defp redact_url_field(url) when is_binary(url), do: Redactor.redact_url(url)
  defp redact_url_field(url), do: url
end
