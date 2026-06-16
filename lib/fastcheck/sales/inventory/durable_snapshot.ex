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
  @non_expirable_order_statuses ~w(
    paid_unverified paid_verified fulfillment_queued ticket_issued partially_issued
    manual_review refunded cancelled expired
  )
  @expirable_unpaid_order_statuses ~w(awaiting_payment payment_pending draft)

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

  @type hold_expiry_class ::
          :expirable_unpaid
          | :paid_or_fulfilled
          | :manual_review
          | :refunded_or_terminal
          | :missing_order
          | :session_still_active

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

  @spec order_public_references(integer()) :: {:ok, MapSet.t(String.t())}
  def order_public_references(offer_id) when is_integer(offer_id) do
    result =
      Repo.query!(
        """
        SELECT DISTINCT o.public_reference
        FROM sales_orders o
        INNER JOIN sales_order_lines ol ON ol.sales_order_id = o.id
        WHERE ol.ticket_offer_id = $1
        """,
        [offer_id]
      )

    refs = for [ref] <- result.rows, do: ref
    {:ok, MapSet.new(refs)}
  end

  @spec classify_hold_ref_for_expiry(integer(), String.t()) :: hold_expiry_class()
  def classify_hold_ref_for_expiry(offer_id, public_reference)
      when is_integer(offer_id) and is_binary(public_reference) do
    result =
      Repo.query!(
        """
        SELECT o.status,
               cs.status,
               cs.expires_at,
               cs.released_at,
               cs.expired_at
        FROM sales_orders o
        INNER JOIN sales_order_lines ol ON ol.sales_order_id = o.id AND ol.ticket_offer_id = $1
        LEFT JOIN sales_checkout_sessions cs ON cs.sales_order_id = o.id
        WHERE o.public_reference = $2
        ORDER BY cs.inserted_at DESC NULLS LAST
        LIMIT 1
        """,
        [offer_id, public_reference]
      )

    case result.rows do
      [] ->
        :missing_order

      [[order_status, _session_status, expires_at, released_at, expired_at]] ->
        cond do
          order_status in @non_expirable_order_statuses ->
            if order_status == "manual_review", do: :manual_review, else: :paid_or_fulfilled

          order_status in @terminal_order_statuses ->
            :refunded_or_terminal

          order_status in @expirable_unpaid_order_statuses ->
            if session_expired?(expires_at, released_at, expired_at) do
              :expirable_unpaid
            else
              :session_still_active
            end

          true ->
            :paid_or_fulfilled
        end
    end
  end

  @spec expirable_unpaid_hold_refs(integer(), [String.t()]) :: [String.t()]
  def expirable_unpaid_hold_refs(offer_id, hold_refs)
      when is_integer(offer_id) and is_list(hold_refs) do
    Enum.filter(hold_refs, fn ref ->
      classify_hold_ref_for_expiry(offer_id, ref) == :expirable_unpaid
    end)
  end

  defp session_expired?(expires_at, released_at, expired_at) do
    cond do
      not is_nil(expired_at) -> true
      not is_nil(released_at) -> true
      is_nil(expires_at) -> false
      true -> DateTime.compare(normalize_utc_datetime(expires_at), DateTime.utc_now()) != :gt
    end
  end

  defp normalize_utc_datetime(%DateTime{} = dt), do: dt

  defp normalize_utc_datetime(%NaiveDateTime{} = naive),
    do: DateTime.from_naive!(naive, "Etc/UTC")

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
