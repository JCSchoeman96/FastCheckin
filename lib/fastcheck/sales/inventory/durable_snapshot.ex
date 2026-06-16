defmodule FastCheck.Sales.Inventory.DurableSnapshot do
  @moduledoc """
  Offer-scoped durable inventory counts for FastCheck Sales reconciliation.

  Reads Postgres/Ash Sales state only. Does not mutate checkout, orders, or Redis.
  """

  alias FastCheck.Repo
  alias FastCheck.Sales.TicketOffer

  @sold_order_statuses ~w(paid_verified fulfillment_queued ticket_issued partially_issued)
  @active_hold_session_statuses ~w(hold_attached payment_link_sent payment_started)
  @terminal_order_statuses ~w(cancelled expired refunded)

  @type t :: %{
          offer_id: integer(),
          event_id: integer(),
          configured_quantity: non_neg_integer(),
          sold_count: non_neg_integer(),
          active_hold_count: non_neg_integer(),
          manual_review_order_count: non_neg_integer(),
          safe_available: integer(),
          manual_review_required?: boolean(),
          anomalies: [map()]
        }

  @spec fetch(integer()) :: {:ok, t()} | {:error, :offer_not_found}
  def fetch(offer_id) when is_integer(offer_id) do
    case Ash.get(TicketOffer, offer_id, authorize?: false) do
      {:ok, nil} ->
        {:error, :offer_not_found}

      {:ok, offer} ->
        sold_count = sold_quantity(offer_id)
        active_hold_count = active_hold_quantity(offer_id)
        manual_review_order_count = manual_review_quantity(offer_id)
        configured = offer.configured_quantity_available
        safe_available = configured - sold_count - active_hold_count

        anomalies =
          []
          |> maybe_add(safe_available < 0, %{
            code: :negative_safe_available,
            safe_available: safe_available
          })
          |> maybe_add(manual_review_order_count > 0, %{
            code: :manual_review_orders_present,
            count: manual_review_order_count
          })

        manual_review_required? = safe_available < 0 or manual_review_order_count > 0

        {:ok,
         %{
           offer_id: offer_id,
           event_id: offer.event_id,
           configured_quantity: configured,
           sold_count: sold_count,
           active_hold_count: active_hold_count,
           manual_review_order_count: manual_review_order_count,
           safe_available: safe_available,
           manual_review_required?: manual_review_required?,
           anomalies: anomalies
         }}

      {:error, _} ->
        {:error, :offer_not_found}
    end
  end

  defp sold_quantity(offer_id) do
    result =
      Repo.query!(
        """
        SELECT COALESCE(SUM(ol.quantity), 0)::bigint
        FROM sales_order_lines ol
        INNER JOIN sales_orders o ON o.id = ol.sales_order_id
        WHERE ol.ticket_offer_id = $1
          AND o.status = ANY($2::text[])
        """,
        [offer_id, @sold_order_statuses]
      )

    scalar_to_int(result)
  end

  defp active_hold_quantity(offer_id) do
    result =
      Repo.query!(
        """
        SELECT COALESCE(SUM(COALESCE(cs.hold_quantity, ol.quantity)), 0)::bigint
        FROM sales_order_lines ol
        INNER JOIN sales_orders o ON o.id = ol.sales_order_id
        INNER JOIN sales_checkout_sessions cs ON cs.sales_order_id = o.id
        WHERE ol.ticket_offer_id = $1
          AND cs.status = ANY($2::text[])
          AND cs.released_at IS NULL
          AND cs.expired_at IS NULL
          AND o.status <> ALL($3::text[])
          AND (cs.expires_at IS NULL OR cs.expires_at > now() AT TIME ZONE 'utc')
        """,
        [offer_id, @active_hold_session_statuses, @terminal_order_statuses]
      )

    scalar_to_int(result)
  end

  defp manual_review_quantity(offer_id) do
    result =
      Repo.query!(
        """
        SELECT COALESCE(SUM(ol.quantity), 0)::bigint
        FROM sales_order_lines ol
        INNER JOIN sales_orders o ON o.id = ol.sales_order_id
        WHERE ol.ticket_offer_id = $1
          AND o.status = 'manual_review'
        """,
        [offer_id]
      )

    scalar_to_int(result)
  end

  defp scalar_to_int(%{rows: [[value]]}) when is_integer(value), do: value

  defp scalar_to_int(%{rows: [[value]]}), do: value |> to_string() |> String.to_integer()

  defp maybe_add(list, false, _item), do: list
  defp maybe_add(list, true, item), do: [item | list]
end
