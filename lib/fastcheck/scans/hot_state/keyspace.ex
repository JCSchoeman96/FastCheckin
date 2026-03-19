defmodule FastCheck.Scans.HotState.Keyspace do
  @moduledoc """
  Redis key helpers for mobile scan hot state.
  """

  @prefix "fastcheck:mobile_scans"

  @spec active_version(String.t(), integer()) :: String.t()
  def active_version(namespace, event_id) do
    "#{base(namespace, event_id)}:active_version"
  end

  @spec build_lock(String.t(), integer()) :: String.t()
  def build_lock(namespace, event_id) do
    "#{base(namespace, event_id)}:build_lock"
  end

  @spec idempotency(String.t(), integer(), String.t()) :: String.t()
  def idempotency(namespace, event_id, idempotency_key) do
    "#{base(namespace, event_id)}:idempotency:#{idempotency_key}"
  end

  @spec ticket(String.t(), integer(), String.t(), String.t()) :: String.t()
  def ticket(namespace, event_id, version, ticket_code) do
    "#{base(namespace, event_id)}:version:#{version}:ticket:#{ticket_code}"
  end

  defp base(namespace, event_id), do: "#{@prefix}:#{namespace}:event:#{event_id}"
end
