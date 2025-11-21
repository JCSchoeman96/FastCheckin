defmodule FastCheckWeb.SentryFilter do
  @moduledoc """
  Sentry event filter to sanitize sensitive data before sending to Sentry.

  Removes or redacts sensitive fields like passwords, tokens, and encryption keys
  from exception reports.
  """

  @behaviour Sentry.EventFilter

  @impl true
  def exclude_exception?(_exception, _source), do: false

  @impl true
  def filter_event(event) do
    event
    |> filter_request_data()
    |> filter_extra_data()
  end

  # Remove sensitive request data
  defp filter_request_data(%{request: request} = event) when is_map(request) do
    filtered_request =
      request
      |> Map.update(:data, %{}, &redact_sensitive_fields/1)
      |> Map.update(:headers, %{}, &redact_sensitive_headers/1)

    %{event | request: filtered_request}
  end

  defp filter_request_data(event), do: event

  # Remove sensitive extra data
  defp filter_extra_data(%{extra: extra} = event) when is_map(extra) do
    %{event | extra: redact_sensitive_fields(extra)}
  end

  defp filter_extra_data(event), do: event

  # Redact sensitive field values
  defp redact_sensitive_fields(data) when is_map(data) do
    Enum.into(data, %{}, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[FILTERED]"}
      else
        {key, value}
      end
    end)
  end

  defp redact_sensitive_fields(data), do: data

  # Redact sensitive headers
  defp redact_sensitive_headers(headers) when is_map(headers) do
    headers
    |> Enum.into(%{}, fn {key, value} ->
      normalized_key = String.downcase(to_string(key))

      if String.contains?(normalized_key, ["authorization", "cookie", "token"]) do
        {key, "[FILTERED]"}
      else
        {key, value}
      end
    end)
  end

  defp redact_sensitive_headers(headers), do: headers

  # Check if a key contains sensitive information
  defp sensitive_key?(key) when is_binary(key) do
    normalized = String.downcase(key)

    String.contains?(normalized, [
      "password",
      "secret",
      "token",
      "key",
      "authorization",
      "cookie",
      "encrypt"
    ])
  end

  defp sensitive_key?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> sensitive_key?()
  end

  defp sensitive_key?(_), do: false
end
