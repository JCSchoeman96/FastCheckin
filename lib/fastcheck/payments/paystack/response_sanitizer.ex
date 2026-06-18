defmodule FastCheck.Payments.Paystack.ResponseSanitizer do
  @moduledoc """
  Sanitizes Paystack provider payloads for logs and safe metadata.
  """

  alias FastCheck.Observability.Redactor

  @sensitive_keys ~w(access_code authorization_url email phone raw_payload raw_initialize_response raw_verify_response)

  @spec sanitize(term()) :: term()
  def sanitize(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {key, raw_value}, acc ->
      if sensitive_key?(key) do
        Map.put(acc, key, Redactor.filtered())
      else
        Map.put(acc, key, sanitize(raw_value))
      end
    end)
  end

  def sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)
  def sanitize(value), do: value

  @doc """
  Removes sensitive keys entirely for persisted provider snapshots (e.g. verify responses).
  """
  @spec drop_sensitive(term()) :: term()
  def drop_sensitive(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _} -> sensitive_key?(key) end)
    |> Enum.into(%{}, fn {key, raw_value} -> {key, drop_sensitive(raw_value)} end)
  end

  def drop_sensitive(value) when is_list(value), do: Enum.map(value, &drop_sensitive/1)
  def drop_sensitive(value), do: value

  defp sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))
  defp sensitive_key?(key) when is_binary(key), do: String.downcase(key) in @sensitive_keys
  defp sensitive_key?(_), do: false
end
