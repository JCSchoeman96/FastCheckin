defmodule FastCheck.Sales.Offers.CacheInvalidation do
  @moduledoc """
  Centralized TicketOffer cache invalidation boundary for FastCheck Sales.

  This module only invalidates durable offer listing cache keys. It must not
  mutate live inventory, reservations, checkout state, or payment flows.
  """

  alias FastCheck.Cache.CacheManager

  @spec invalidate_event_offers(integer()) :: :ok
  def invalidate_event_offers(event_id) when is_integer(event_id) do
    _ = CacheManager.invalidate_pattern("sales:event:#{event_id}:offers*")
    _ = CacheManager.invalidate_pattern("sales:offers:active:event:#{event_id}:*")
    :ok
  end
end
