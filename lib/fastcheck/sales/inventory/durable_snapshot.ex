defmodule FastCheck.Sales.Inventory.DurableSnapshot do
  @moduledoc """
  Offer-scoped durable inventory counts for FastCheck Sales reconciliation.

  Reads Postgres/Ash Sales state only. Does not mutate checkout, orders, or Redis.
  """

  alias FastCheck.Repo
  alias FastCheck.Sales.TicketOffer

  @sold_order_statuses ~w(
    paid_verified fulfillment_queued ticket_issued partially_issued refunded
  )
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
          refund_inventory_pending_count: non_neg_integer(),
          refund_inventory_manual_review_count: non_neg_integer(),
          legacy_refund_count: non_neg_integer(),
          ambiguous_refund_count: non_neg_integer(),
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
        refund_counts = refunded_order_counts(offer_id)
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
          |> maybe_add(refund_counts.pending > 0, %{
            code: :refund_inventory_resolution_pending,
            count: refund_counts.pending
          })
          |> maybe_add(refund_counts.manual_review > 0, %{
            code: :refund_inventory_resolution_manual_review,
            count: refund_counts.manual_review
          })
          |> maybe_add(refund_counts.legacy > 0, %{
            code: :legacy_refund_without_provider_evidence,
            count: refund_counts.legacy
          })
          |> maybe_add(refund_counts.ambiguous > 0, %{
            code: :refund_inventory_resolution_ambiguous,
            count: refund_counts.ambiguous
          })

        manual_review_required? =
          safe_available < 0 or manual_review_order_count > 0 or
            refund_counts.manual_review > 0 or refund_counts.legacy > 0 or
            refund_counts.ambiguous > 0

        {:ok,
         %{
           offer_id: offer_id,
           event_id: offer.event_id,
           configured_quantity: configured,
           sold_count: sold_count,
           active_hold_count: active_hold_count,
           manual_review_order_count: manual_review_order_count,
           refund_inventory_pending_count: refund_counts.pending,
           refund_inventory_manual_review_count: refund_counts.manual_review,
           legacy_refund_count: refund_counts.legacy,
           ambiguous_refund_count: refund_counts.ambiguous,
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
          AND NOT (
            o.status = 'refunded' AND EXISTS (
            SELECT 1
              FROM sales_refunds r
              INNER JOIN sales_payment_attempts p
                ON p.id = r.payment_attempt_id AND p.sales_order_id = o.id
              WHERE r.sales_order_id = o.id
                AND r.status = 'completed'
                AND r.inventory_resolution_status = 'released_unconsumed'
                AND r.provider = 'paystack'
                AND r.provider_status = 'processed'
                AND r.provider_refund_reference IS NOT NULL
                AND btrim(r.provider_refund_reference) <> ''
                AND r.provider_refunded_at IS NOT NULL
                AND r.recorded_by IS NOT NULL
                AND btrim(r.recorded_by) <> ''
                AND r.reason IS NOT NULL
                AND btrim(r.reason) <> ''
                AND r.amount_cents = o.total_amount_cents
                AND r.currency = o.currency
                AND r.revocation_completed_at IS NOT NULL
                AND p.provider = 'paystack'
                AND p.status = 'refunded'
                AND p.amount_cents = o.total_amount_cents
                AND p.currency = o.currency
                AND ol.quantity > 0
                AND ol.total_amount_cents = o.total_amount_cents
                AND ol.currency = o.currency
                AND (SELECT count(*)
                     FROM sales_order_lines refund_lines
                     WHERE refund_lines.sales_order_id = o.id) = 1
                AND (SELECT count(*)
                     FROM sales_payment_attempts candidates
                     WHERE candidates.sales_order_id = o.id
                       AND candidates.status IN ('verified_success', 'refunded')) = 1
                AND NOT EXISTS (
                  SELECT 1 FROM sales_ticket_issues issues
                  WHERE issues.sales_order_id = o.id AND issues.status = 'issued'
                )
            )
          )
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

  defp refunded_order_counts(offer_id) do
    result =
      Repo.query!(
        """
        SELECT
          COUNT(DISTINCT o.id) FILTER (WHERE r.id IS NULL)::bigint,
          COUNT(DISTINCT o.id) FILTER (WHERE r.status = 'inventory_pending')::bigint,
          COUNT(DISTINCT o.id) FILTER (WHERE r.status = 'inventory_manual_review')::bigint,
          COUNT(DISTINCT o.id) FILTER (
            WHERE r.id IS NOT NULL
              AND NOT (
                r.status = 'inventory_pending'
                OR r.status = 'inventory_manual_review'
                OR (r.status = 'completed'
                  AND r.inventory_resolution_status IN ('released_unconsumed', 'retained_consumed')
                  AND r.provider = 'paystack'
                  AND r.provider_status = 'processed'
                  AND r.provider_refund_reference IS NOT NULL
                  AND btrim(r.provider_refund_reference) <> ''
                  AND r.provider_refunded_at IS NOT NULL
                  AND r.recorded_by IS NOT NULL
                  AND btrim(r.recorded_by) <> ''
                  AND r.reason IS NOT NULL
                  AND btrim(r.reason) <> ''
                  AND r.amount_cents = o.total_amount_cents
                  AND r.currency = o.currency
                  AND r.revocation_completed_at IS NOT NULL
                  AND p.provider = 'paystack'
                  AND p.status = 'refunded'
                  AND p.amount_cents = o.total_amount_cents
                  AND p.currency = o.currency
                  AND ol.quantity > 0
                  AND ol.total_amount_cents = o.total_amount_cents
                  AND ol.currency = o.currency
                  AND (SELECT count(*)
                       FROM sales_order_lines refund_lines
                       WHERE refund_lines.sales_order_id = o.id) = 1
                  AND (SELECT count(*)
                       FROM sales_payment_attempts candidates
                       WHERE candidates.sales_order_id = o.id
                         AND candidates.status IN ('verified_success', 'refunded')) = 1
                  AND NOT EXISTS (
                    SELECT 1 FROM sales_ticket_issues issues
                    WHERE issues.sales_order_id = o.id AND issues.status = 'issued'
                  ))
              )
          )::bigint
        FROM sales_orders o
        INNER JOIN sales_order_lines ol ON ol.sales_order_id = o.id
        LEFT JOIN sales_refunds r ON r.sales_order_id = o.id
        LEFT JOIN sales_payment_attempts p
          ON p.id = r.payment_attempt_id AND p.sales_order_id = o.id
        WHERE ol.ticket_offer_id = $1 AND o.status = 'refunded'
        """,
        [offer_id]
      )

    case result.rows do
      [[legacy, pending, manual_review, ambiguous]] ->
        %{
          legacy: to_int(legacy),
          pending: to_int(pending),
          manual_review: to_int(manual_review),
          ambiguous: to_int(ambiguous)
        }
    end
  end

  defp scalar_to_int(%{rows: [[value]]}) when is_integer(value), do: value

  defp scalar_to_int(%{rows: [[value]]}), do: value |> to_string() |> String.to_integer()

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value), do: value |> to_string() |> String.to_integer()

  defp maybe_add(list, false, _item), do: list
  defp maybe_add(list, true, item), do: [item | list]
end
