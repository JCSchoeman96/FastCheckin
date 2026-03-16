defmodule FastCheck.Operations.ActivityFeed do
  @moduledoc """
  Minimal PubSub fan-out for recent scan summaries.
  """

  @pubsub FastCheck.PubSub

  @spec broadcast_scan_summary(integer(), integer() | nil, map()) :: :ok
  def broadcast_scan_summary(event_id, gate_id, payload)
      when is_integer(event_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(@pubsub, event_topic(event_id), {:ops_scan_summary, payload})

    if is_integer(gate_id) do
      Phoenix.PubSub.broadcast(
        @pubsub,
        gate_topic(event_id, gate_id),
        {:ops_scan_summary, payload}
      )
    end

    :ok
  end

  def broadcast_scan_summary(_event_id, _gate_id, _payload), do: :ok

  @spec event_topic(integer()) :: String.t()
  def event_topic(event_id), do: "ops:event:#{event_id}"

  @spec gate_topic(integer(), integer()) :: String.t()
  def gate_topic(event_id, gate_id), do: "ops:event:#{event_id}:gate:#{gate_id}"
end
