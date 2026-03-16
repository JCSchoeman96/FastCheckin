defmodule FastCheck.Operations.ConflictService do
  @moduledoc """
  Minimal conflict count broadcaster for reconciliation dashboards.
  """

  @pubsub FastCheck.PubSub

  @spec broadcast_conflict_count(integer(), non_neg_integer()) :: :ok
  def broadcast_conflict_count(event_id, count)
      when is_integer(event_id) and is_integer(count) and count >= 0 do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "ops:event:#{event_id}:conflicts",
      {:ops_conflict_count, %{count: count}}
    )

    :ok
  end

  def broadcast_conflict_count(_event_id, _count), do: :ok
end
