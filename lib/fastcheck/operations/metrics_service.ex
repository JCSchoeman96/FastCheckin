defmodule FastCheck.Operations.MetricsService do
  @moduledoc """
  Minimal device-health PubSub surface for operations dashboards.
  """

  @pubsub FastCheck.PubSub

  @spec broadcast_device_health(integer(), map()) :: :ok
  def broadcast_device_health(event_id, payload) when is_integer(event_id) and is_map(payload) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "ops:event:#{event_id}:devices",
      {:ops_device_health, payload}
    )

    :ok
  end

  def broadcast_device_health(_event_id, _payload), do: :ok
end
