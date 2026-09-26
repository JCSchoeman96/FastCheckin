defmodule FastCheck.SalesEventFkTestSupport do
  @moduledoc false

  alias FastCheck.SalesCheckoutFixtures

  @spec ensure_events!([pos_integer()]) :: :ok
  def ensure_events!(event_ids) when is_list(event_ids) do
    for event_id <- event_ids, do: SalesCheckoutFixtures.ensure_event_for_sales!(event_id)
    :ok
  end
end
