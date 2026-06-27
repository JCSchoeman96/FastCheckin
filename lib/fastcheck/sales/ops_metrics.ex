defmodule FastCheck.Sales.OpsMetrics do
  @moduledoc """
  Read-only operational metrics for FastCheck Sales.

  This module intentionally returns safe display maps only. It does not call
  provider clients, ticket issuance, scanner mutation, Redis inventory, or Sales
  workflow actions.
  """

  import Ecto.Query

  alias FastCheck.Repo

  @default_window "1h"
  @windows %{
    "15m" => 15 * 60,
    "1h" => 60 * 60,
    "24h" => 24 * 60 * 60,
    "7d" => 7 * 24 * 60 * 60
  }
  @default_limit 25
  @max_limit 50
  @review_payment_statuses ~w(verified_amount_mismatch verified_currency_mismatch failed manual_review)
  @active_checkout_statuses ~w(hold_attached payment_link_sent payment_started)

  @doc "Returns bounded Sales operational counters."
  def summary(filters \\ %{}) do
    filters = normalize_filters(filters)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    from_dt = DateTime.add(now, -Map.fetch!(@windows, filters.window), :second)

    %{
      window: filters.window,
      window_from: from_dt,
      window_to: now,
      orders_by_status: grouped_orders(filters, from_dt, :status),
      orders_by_source_channel: grouped_orders(filters, from_dt, :source_channel),
      checkout_expiring_soon_count: checkout_expiring_soon_count(filters, now),
      checkout_expired_unreleased_count: checkout_expired_unreleased_count(filters, from_dt),
      payment_attempts_by_status: payment_attempts_by_status(filters, from_dt),
      payment_mismatch_count: payment_mismatch_count(filters, from_dt),
      payment_unmatched_event_count: payment_event_count("unmatched", from_dt),
      payment_webhook_duplicate_count: payment_event_count("duplicate", from_dt),
      tickets_issued_count: ticket_status_count("issued", filters, from_dt),
      tickets_partially_issued_count: order_status_count("partially_issued", filters, from_dt),
      ticket_issue_failure_count: ticket_status_count("manual_review", filters, from_dt),
      tickets_revoked_count: ticket_status_count("revoked", filters, from_dt),
      scanner_visibility_pending_count: scanner_visibility_pending_count(filters, from_dt),
      delivery_attempts_by_status: delivery_attempts_by_status(filters, from_dt),
      delivery_fallback_required_count:
        delivery_status_count("fallback_required", filters, from_dt),
      manual_review_open_count: manual_review_open_count(filters, from_dt),
      manual_review_oldest_age_seconds: manual_review_oldest_age_seconds(filters, from_dt, now),
      worker_retry_backlog_by_queue: worker_retry_backlog_by_queue()
    }
  end

  @doc "Returns bounded recent failure rows for the ops dashboard."
  def recent_failures(filters \\ %{}, opts \\ []) do
    filters = normalize_filters(filters)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    from_dt = DateTime.add(now, -Map.fetch!(@windows, filters.window), :second)
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit)

    "sales_payment_attempts"
    |> join(:inner, [p], o in "sales_orders", on: o.id == p.sales_order_id)
    |> where([p, _o], p.status in ^@review_payment_statuses)
    |> where([p, _o], p.inserted_at >= ^from_dt)
    |> maybe_filter_joined_event(filters.event_id)
    |> order_by([p, _o], desc: p.inserted_at, desc: p.id)
    |> limit(^limit)
    |> select([p, o], %{
      id: p.id,
      kind: "payment_attempt",
      status: p.status,
      reason_code: p.manual_review_reason,
      order_id: o.id,
      order_public_reference: o.public_reference,
      event_id: o.event_id,
      source_channel: o.source_channel,
      inserted_at: p.inserted_at
    })
    |> Repo.all()
  end

  defp grouped_orders(filters, from_dt, field) do
    group_field = field

    "sales_orders"
    |> where([o], o.inserted_at >= ^from_dt)
    |> maybe_filter_event(filters.event_id)
    |> maybe_filter_source_channel(filters.source_channel)
    |> group_by([o], field(o, ^group_field))
    |> select([o], {field(o, ^group_field), count(o.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp checkout_expiring_soon_count(filters, now) do
    soon = DateTime.add(now, 15 * 60, :second)

    "sales_checkout_sessions"
    |> join(:inner, [c], o in "sales_orders", on: o.id == c.sales_order_id)
    |> where([c, _o], c.status in ^@active_checkout_statuses)
    |> where([c, _o], c.expires_at >= ^now and c.expires_at <= ^soon)
    |> maybe_filter_joined_event(filters.event_id)
    |> Repo.aggregate(:count, :id)
  end

  defp checkout_expired_unreleased_count(filters, from_dt) do
    "sales_checkout_sessions"
    |> join(:inner, [c], o in "sales_orders", on: o.id == c.sales_order_id)
    |> where([c, _o], c.status == "expired" and is_nil(c.released_at))
    |> where([c, _o], c.expires_at >= ^from_dt)
    |> maybe_filter_joined_event(filters.event_id)
    |> Repo.aggregate(:count, :id)
  end

  defp payment_attempts_by_status(filters, from_dt) do
    "sales_payment_attempts"
    |> join(:inner, [p], o in "sales_orders", on: o.id == p.sales_order_id)
    |> where([p, _o], p.inserted_at >= ^from_dt)
    |> maybe_filter_joined_event(filters.event_id)
    |> group_by([p, _o], p.status)
    |> select([p, _o], {p.status, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp payment_mismatch_count(filters, from_dt) do
    "sales_payment_attempts"
    |> join(:inner, [p], o in "sales_orders", on: o.id == p.sales_order_id)
    |> where([p, _o], p.status in ["verified_amount_mismatch", "verified_currency_mismatch"])
    |> where([p, _o], p.inserted_at >= ^from_dt)
    |> maybe_filter_joined_event(filters.event_id)
    |> Repo.aggregate(:count, :id)
  end

  defp payment_event_count(status, from_dt) do
    "sales_payment_events"
    |> where([e], e.processing_status == ^status)
    |> where([e], e.inserted_at >= ^from_dt)
    |> Repo.aggregate(:count, :id)
  end

  defp ticket_status_count(status, filters, from_dt) do
    "sales_ticket_issues"
    |> join(:inner, [t], o in "sales_orders", on: o.id == t.sales_order_id)
    |> where([t, _o], t.status == ^status)
    |> where([t, _o], t.inserted_at >= ^from_dt)
    |> maybe_filter_joined_event(filters.event_id)
    |> Repo.aggregate(:count, :id)
  end

  defp order_status_count(status, filters, from_dt) do
    "sales_orders"
    |> where([o], o.status == ^status)
    |> where([o], o.inserted_at >= ^from_dt)
    |> maybe_filter_event(filters.event_id)
    |> Repo.aggregate(:count, :id)
  end

  defp scanner_visibility_pending_count(filters, from_dt) do
    "attendee_invalidation_events"
    |> where([i], i.inserted_at >= ^from_dt)
    |> maybe_filter_event(filters.event_id)
    |> Repo.aggregate(:count, :id)
  end

  defp delivery_attempts_by_status(filters, from_dt) do
    "sales_delivery_attempts"
    |> join(:inner, [d], o in "sales_orders", on: o.id == d.sales_order_id)
    |> where([d, _o], d.inserted_at >= ^from_dt)
    |> maybe_filter_joined_event(filters.event_id)
    |> group_by([d, _o], d.status)
    |> select([d, _o], {d.status, count(d.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp delivery_status_count(status, filters, from_dt) do
    "sales_delivery_attempts"
    |> join(:inner, [d], o in "sales_orders", on: o.id == d.sales_order_id)
    |> where([d, _o], d.status == ^status)
    |> where([d, _o], d.inserted_at >= ^from_dt)
    |> maybe_filter_joined_event(filters.event_id)
    |> Repo.aggregate(:count, :id)
  end

  defp manual_review_open_count(filters, from_dt) do
    "sales_orders"
    |> where([o], o.status == "manual_review")
    |> where([o], o.inserted_at >= ^from_dt)
    |> maybe_filter_event(filters.event_id)
    |> Repo.aggregate(:count, :id)
  end

  defp manual_review_oldest_age_seconds(filters, from_dt, now) do
    oldest =
      "sales_orders"
      |> where([o], o.status == "manual_review")
      |> where([o], o.inserted_at >= ^from_dt)
      |> maybe_filter_event(filters.event_id)
      |> select([o], min(o.inserted_at))
      |> Repo.one()

    case oldest do
      nil ->
        nil

      %DateTime{} = dt ->
        max(DateTime.diff(now, dt, :second), 0)

      %NaiveDateTime{} = dt ->
        max(DateTime.diff(now, DateTime.from_naive!(dt, "Etc/UTC"), :second), 0)
    end
  end

  defp worker_retry_backlog_by_queue do
    Oban.Job
    |> where([j], j.state in ["retryable", "scheduled"] and j.attempt > 0)
    |> group_by([j], j.queue)
    |> select([j], {j.queue, count(j.id)})
    |> Repo.all()
    |> Map.new()
  rescue
    _ -> %{}
  end

  defp normalize_filters(filters) when is_map(filters) do
    %{
      event_id:
        filters
        |> get_filter("event_id")
        |> parse_optional_integer(),
      source_channel:
        filters
        |> get_filter("source_channel")
        |> clean_allowed(),
      window:
        filters
        |> get_filter("window")
        |> normalize_window()
    }
  end

  defp normalize_filters(_), do: normalize_filters(%{})

  defp get_filter(map, "event_id"), do: Map.get(map, "event_id") || Map.get(map, :event_id)

  defp get_filter(map, "source_channel"),
    do: Map.get(map, "source_channel") || Map.get(map, :source_channel)

  defp get_filter(map, "window"), do: Map.get(map, "window") || Map.get(map, :window)

  defp normalize_window(value) when is_binary(value) do
    if Map.has_key?(@windows, value), do: value, else: @default_window
  end

  defp normalize_window(_), do: @default_window

  defp parse_optional_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp parse_optional_integer(_), do: nil

  defp clean_allowed(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" or not String.match?(value, ~r/^[a-zA-Z0-9_:-]+$/) do
      nil
    else
      value
    end
  end

  defp clean_allowed(_), do: nil

  defp maybe_filter_event(query, nil), do: query
  defp maybe_filter_event(query, event_id), do: where(query, [row], row.event_id == ^event_id)

  defp maybe_filter_joined_event(query, nil), do: query

  defp maybe_filter_joined_event(query, event_id),
    do: where(query, [_left, o], o.event_id == ^event_id)

  defp maybe_filter_source_channel(query, nil), do: query

  defp maybe_filter_source_channel(query, source_channel),
    do: where(query, [o], o.source_channel == ^source_channel)

  defp clamp(value, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp clamp(_value, min, _max), do: min
end
