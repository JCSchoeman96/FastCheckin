defmodule FastCheck.Sales.AdminDashboard do
  @moduledoc """
  Read-only Sales admin dashboard query boundary.

  Public functions return safe display maps only. Raw provider payloads, token
  material, ticket codes, idempotency keys, and unmasked buyer contact fields are
  intentionally not returned.
  """

  import Ecto.Query

  alias FastCheck.Repo
  alias FastCheck.Sales.Inventory.Health

  @default_limit 25
  @max_limit 100
  @max_inventory_limit 25
  @default_window_days 30
  @max_window_days 90
  @payment_review_statuses ~w(verified_amount_mismatch verified_currency_mismatch failed manual_review)
  @review_ticket_statuses ~w(manual_review revoked)

  @doc """
  Returns bounded dashboard summary counts.
  """
  def summary(filters \\ %{}) do
    filters = normalize_filters(filters)
    {from_dt, to_dt} = date_window(filters)
    order_query = filtered_orders_query(filters, from_dt, to_dt)

    %{
      orders_in_window: Repo.aggregate(order_query, :count, :id),
      paid_verified: count_orders_by_status(order_query, "paid_verified"),
      issued: count_issued_tickets(filters, from_dt, to_dt),
      failed_mismatch: count_distinct_orders_with_payment_status(filters, from_dt, to_dt),
      manual_review_open: count_open_manual_review(filters),
      expired_checkout: count_checkout_status(filters, from_dt, to_dt, "expired"),
      window_from: from_dt,
      window_to: to_dt
    }
  end

  @doc """
  Returns recent safe order summaries.
  """
  def recent_orders(filters \\ %{}, opts \\ []) do
    filters = normalize_filters(filters)
    limit = limit(opts)
    {from_dt, to_dt} = date_window(filters)

    rows =
      filters
      |> filtered_orders_query(from_dt, to_dt)
      |> maybe_filter_payment_status(filters.payment_status)
      |> order_by([o], desc: o.inserted_at, desc: o.id)
      |> limit(^limit)
      |> select([o], %{
        id: o.id,
        order_public_reference: o.public_reference,
        order_status: o.status,
        source_channel: o.source_channel,
        event_id: o.event_id,
        buyer_name: o.buyer_name,
        buyer_email_private: o.buyer_email,
        buyer_phone_private: o.buyer_phone,
        amount_cents: o.total_amount_cents,
        currency: o.currency,
        manual_review_reason: o.manual_review_reason,
        inserted_at: o.inserted_at,
        updated_at: o.updated_at
      })
      |> Repo.all()

    enrich_order_rows(rows)
  end

  @doc """
  Returns bounded manual review rows.
  """
  def manual_review_queue(filters \\ %{}, opts \\ []) do
    filters = normalize_filters(filters)
    limit = limit(opts)
    {from_dt, to_dt} = date_window(filters)

    review_order_ids =
      filters
      |> manual_review_order_id_query(from_dt, to_dt)
      |> limit(^limit)
      |> Repo.all()

    review_order_ids
    |> orders_by_ids()
    |> enrich_order_rows()
    |> Enum.map(&review_row/1)
  end

  @doc """
  Returns one safe order detail map.
  """
  def order_detail(order_id) do
    with {:ok, id} <- parse_integer(order_id),
         [row] <- orders_by_ids([id]) do
      [detail] = enrich_order_rows([row])

      {:ok,
       detail
       |> Map.put(:order_lines_count, count_order_lines(id))
       |> Map.put(:state_transition_count, count_state_transitions(id))}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns capped read-only inventory health summaries for visible offers.
  """
  def inventory_summary(filters \\ %{}, opts \\ []) do
    filters = normalize_filters(filters)
    limit = opts |> Keyword.get(:limit, @max_inventory_limit) |> clamp(1, @max_inventory_limit)

    "sales_ticket_offers"
    |> where([o], is_nil(o.archived_at))
    |> maybe_filter_event(filters.event_id)
    |> order_by([o], desc: o.inserted_at, desc: o.id)
    |> limit(^limit)
    |> select([o], %{
      offer_id: o.id,
      event_id: o.event_id,
      name: o.name,
      configured_quantity: o.configured_quantity_available,
      sales_channel: o.sales_channel,
      sales_enabled: o.sales_enabled
    })
    |> Repo.all()
    |> Enum.map(&attach_inventory_health/1)
  end

  defp filtered_orders_query(filters, from_dt, to_dt) do
    "sales_orders"
    |> where([o], o.inserted_at >= ^from_dt and o.inserted_at <= ^to_dt)
    |> maybe_filter_event(filters.event_id)
    |> maybe_filter_status(filters.status)
    |> maybe_filter_source_channel(filters.source_channel)
    |> maybe_filter_public_reference(filters.search)
    |> maybe_filter_manual_review_only(filters.manual_review_only)
  end

  defp manual_review_order_id_query(filters, from_dt, to_dt) do
    payment_review =
      from p in "sales_payment_attempts",
        where: p.status in ^@payment_review_statuses,
        select: p.sales_order_id

    checkout_review =
      from c in "sales_checkout_sessions",
        where: c.status == "manual_review",
        select: c.sales_order_id

    ticket_review =
      from t in "sales_ticket_issues",
        where: t.status in ^@review_ticket_statuses,
        select: t.sales_order_id

    "sales_orders"
    |> where([o], o.inserted_at >= ^from_dt and o.inserted_at <= ^to_dt)
    |> maybe_filter_event(filters.event_id)
    |> maybe_filter_public_reference(filters.search)
    |> where(
      [o],
      o.status == "manual_review" or
        o.id in subquery(payment_review) or
        o.id in subquery(checkout_review) or
        o.id in subquery(ticket_review)
    )
    |> order_by([o], desc: o.inserted_at, desc: o.id)
    |> select([o], o.id)
  end

  defp orders_by_ids([]), do: []

  defp orders_by_ids(ids) do
    "sales_orders"
    |> where([o], o.id in ^ids)
    |> order_by([o], fragment("array_position(?, ?)", ^ids, o.id))
    |> select([o], %{
      id: o.id,
      order_public_reference: o.public_reference,
      order_status: o.status,
      source_channel: o.source_channel,
      event_id: o.event_id,
      buyer_name: o.buyer_name,
      buyer_email_private: o.buyer_email,
      buyer_phone_private: o.buyer_phone,
      amount_cents: o.total_amount_cents,
      currency: o.currency,
      manual_review_reason: o.manual_review_reason,
      inserted_at: o.inserted_at,
      updated_at: o.updated_at
    })
    |> Repo.all()
  end

  defp enrich_order_rows(rows) do
    order_ids = Enum.map(rows, & &1.id)
    latest_payments = latest_payment_by_order(order_ids)
    latest_checkouts = latest_checkout_by_order(order_ids)
    ticket_counts = ticket_counts_by_order(order_ids)
    expected_counts = expected_ticket_counts_by_order(order_ids)
    payment_event_counts = payment_event_counts_for_visible_payments(latest_payments)

    Enum.map(rows, fn row ->
      payment = Map.get(latest_payments, row.id, %{})
      checkout = Map.get(latest_checkouts, row.id, %{})
      ticket = Map.get(ticket_counts, row.id, %{})
      expected = Map.get(expected_counts, row.id, 0)
      provider_reference = Map.get(payment, :provider_reference)

      row
      |> Map.drop([:buyer_email_private, :buyer_phone_private])
      |> Map.put(:buyer_email_masked, mask_email(row.buyer_email_private))
      |> Map.put(:buyer_phone_masked, mask_phone(row.buyer_phone_private))
      |> Map.put(:payment_status_summary, Map.get(payment, :status, "none"))
      |> Map.put(:payment_manual_review_reason, Map.get(payment, :manual_review_reason))
      |> Map.put(:checkout_status, Map.get(checkout, :status, "none"))
      |> Map.put(:issued_ticket_count, Map.get(ticket, :issued, 0))
      |> Map.put(:ticket_issue_count, Map.get(ticket, :total, 0))
      |> Map.put(:attendee_link_count, Map.get(ticket, :attendee_linked, 0))
      |> Map.put(:expected_ticket_count, expected)
      |> Map.put(
        :payment_event_status_summary,
        Map.get(payment_event_counts, provider_reference, %{})
      )
    end)
  end

  defp latest_payment_by_order([]), do: %{}

  defp latest_payment_by_order(order_ids) do
    ranked =
      from p in "sales_payment_attempts",
        where: p.sales_order_id in ^order_ids,
        select: %{
          sales_order_id: p.sales_order_id,
          provider_reference: p.provider_reference,
          status: p.status,
          manual_review_reason: p.manual_review_reason,
          inserted_at: p.inserted_at,
          id: p.id,
          row_number:
            over(row_number(),
              partition_by: p.sales_order_id,
              order_by: [desc: p.inserted_at, desc: p.id]
            )
        }

    ranked
    |> subquery()
    |> where([p], p.row_number == 1)
    |> select([p], %{
      sales_order_id: p.sales_order_id,
      provider_reference: p.provider_reference,
      status: p.status,
      manual_review_reason: p.manual_review_reason
    })
    |> Repo.all()
    |> Map.new(&{&1.sales_order_id, &1})
  end

  defp latest_checkout_by_order([]), do: %{}

  defp latest_checkout_by_order(order_ids) do
    "sales_checkout_sessions"
    |> where([c], c.sales_order_id in ^order_ids)
    |> distinct([c], c.sales_order_id)
    |> order_by([c], asc: c.sales_order_id, desc: c.inserted_at, desc: c.id)
    |> select([c], %{sales_order_id: c.sales_order_id, status: c.status})
    |> Repo.all()
    |> Map.new(&{&1.sales_order_id, &1})
  end

  defp ticket_counts_by_order([]), do: %{}

  defp ticket_counts_by_order(order_ids) do
    "sales_ticket_issues"
    |> where([t], t.sales_order_id in ^order_ids)
    |> group_by([t], t.sales_order_id)
    |> select([t], %{
      sales_order_id: t.sales_order_id,
      total: count(t.id),
      issued: filter(count(t.id), t.status == "issued"),
      attendee_linked: filter(count(t.id), not is_nil(t.attendee_id))
    })
    |> Repo.all()
    |> Map.new(&{&1.sales_order_id, &1})
  end

  defp expected_ticket_counts_by_order([]), do: %{}

  defp expected_ticket_counts_by_order(order_ids) do
    "sales_order_lines"
    |> where([l], l.sales_order_id in ^order_ids)
    |> group_by([l], l.sales_order_id)
    |> select([l], %{sales_order_id: l.sales_order_id, quantity: coalesce(sum(l.quantity), 0)})
    |> Repo.all()
    |> Map.new(&{&1.sales_order_id, &1.quantity})
  end

  defp payment_event_counts_for_visible_payments(payment_by_order) do
    references =
      payment_by_order
      |> Map.values()
      |> Enum.map(& &1.provider_reference)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case references do
      [] ->
        %{}

      _ ->
        "sales_payment_events"
        |> where([e], e.provider_reference in ^references)
        |> group_by([e], [e.provider_reference, e.processing_status])
        |> select([e], %{
          provider_reference: e.provider_reference,
          status: e.processing_status,
          count: count(e.id)
        })
        |> Repo.all()
        |> Enum.group_by(& &1.provider_reference)
        |> Map.new(fn {provider_reference, rows} ->
          counts =
            rows
            |> Map.new(fn row ->
              {String.to_atom(row.status), row.count}
            end)

          {provider_reference, counts}
        end)
    end
  end

  defp count_orders_by_status(query, status) do
    query
    |> where([o], o.status == ^status)
    |> Repo.aggregate(:count, :id)
  end

  defp count_open_manual_review(filters) do
    "sales_orders"
    |> where([o], o.status == "manual_review")
    |> maybe_filter_event(filters.event_id)
    |> Repo.aggregate(:count, :id)
  end

  defp count_distinct_orders_with_payment_status(filters, from_dt, to_dt) do
    "sales_payment_attempts"
    |> join(:inner, [p], o in "sales_orders", on: o.id == p.sales_order_id)
    |> where([p, o], p.status in ^@payment_review_statuses)
    |> where([p, o], o.inserted_at >= ^from_dt and o.inserted_at <= ^to_dt)
    |> maybe_filter_joined_event(filters.event_id)
    |> select([p, _o], p.sales_order_id)
    |> distinct(true)
    |> Repo.aggregate(:count)
  end

  defp count_checkout_status(filters, from_dt, to_dt, status) do
    "sales_checkout_sessions"
    |> join(:inner, [c], o in "sales_orders", on: o.id == c.sales_order_id)
    |> where([c, o], c.status == ^status)
    |> where([c, o], o.inserted_at >= ^from_dt and o.inserted_at <= ^to_dt)
    |> maybe_filter_joined_event(filters.event_id)
    |> Repo.aggregate(:count)
  end

  defp count_issued_tickets(filters, from_dt, to_dt) do
    "sales_ticket_issues"
    |> join(:inner, [t], o in "sales_orders", on: o.id == t.sales_order_id)
    |> where([t, o], t.status == "issued")
    |> where([t, o], o.inserted_at >= ^from_dt and o.inserted_at <= ^to_dt)
    |> maybe_filter_joined_event(filters.event_id)
    |> Repo.aggregate(:count)
  end

  defp count_order_lines(order_id) do
    "sales_order_lines"
    |> where([l], l.sales_order_id == ^order_id)
    |> Repo.aggregate(:count, :id)
  end

  defp count_state_transitions(order_id) do
    order_entity_id = Integer.to_string(order_id)

    "sales_state_transitions"
    |> where([s], s.entity_type == "Order" and s.entity_id == ^order_entity_id)
    |> Repo.aggregate(:count, :id)
  end

  defp review_row(row) do
    reason =
      row.manual_review_reason ||
        row.payment_manual_review_reason ||
        "manual_review_required"

    %{
      id: row.id,
      order_public_reference: row.order_public_reference,
      reason_code: reason,
      reason_summary: reason |> to_string() |> String.replace("_", " "),
      source_channel: row.source_channel,
      payment_attempt_status: row.payment_status_summary,
      payment_event_status_summary: row.payment_event_status_summary,
      checkout_status: row.checkout_status,
      created_at: row.inserted_at,
      last_transition_at: row.updated_at,
      recommended_action: "Open detail and review supporting status summaries",
      buyer_email_masked: row.buyer_email_masked,
      buyer_phone_masked: row.buyer_phone_masked
    }
  end

  defp attach_inventory_health(offer) do
    case Health.offer_health(offer.offer_id) do
      {:ok, health} ->
        Map.merge(offer, %{
          inventory_status: health.status,
          redis_available: health.redis_available,
          active_hold_count: health.active_hold_count,
          sold_count: health.sold_count,
          manual_review_required?: health.manual_review_required?
        })

      {:error, reason} ->
        Map.merge(offer, %{
          inventory_status: reason,
          redis_available: nil,
          active_hold_count: nil,
          sold_count: nil,
          manual_review_required?: true
        })
    end
  end

  defp normalize_filters(filters) when is_map(filters) do
    %{
      event_id:
        parse_optional_integer(Map.get(filters, "event_id") || Map.get(filters, :event_id)),
      status: clean_allowed(Map.get(filters, "status") || Map.get(filters, :status)),
      source_channel:
        clean_allowed(Map.get(filters, "source_channel") || Map.get(filters, :source_channel)),
      payment_status:
        clean_allowed(Map.get(filters, "payment_status") || Map.get(filters, :payment_status)),
      manual_review_only:
        truthy?(Map.get(filters, "manual_review_only") || Map.get(filters, :manual_review_only)),
      from_date: parse_date(Map.get(filters, "from_date") || Map.get(filters, :from_date)),
      to_date: parse_date(Map.get(filters, "to_date") || Map.get(filters, :to_date)),
      search: clean_search(Map.get(filters, "search") || Map.get(filters, :search))
    }
  end

  defp normalize_filters(_), do: normalize_filters(%{})

  defp date_window(%{from_date: nil, to_date: nil}) do
    today = Date.utc_today()
    from_date = Date.add(today, -@default_window_days)
    {date_start(from_date), date_end(today)}
  end

  defp date_window(%{from_date: from_date, to_date: to_date}) do
    today = Date.utc_today()
    to_date = to_date || today
    from_date = from_date || Date.add(to_date, -@default_window_days)

    cond do
      Date.compare(from_date, to_date) == :gt ->
        {date_start(today), date_end(Date.add(today, -1))}

      Date.diff(to_date, from_date) > @max_window_days ->
        {to_date |> Date.add(-@max_window_days) |> date_start(), date_end(to_date)}

      true ->
        {date_start(from_date), date_end(to_date)}
    end
  end

  defp date_start(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp date_end(date), do: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

  defp maybe_filter_event(query, nil), do: query
  defp maybe_filter_event(query, event_id), do: where(query, [o], o.event_id == ^event_id)

  defp maybe_filter_joined_event(query, nil), do: query

  defp maybe_filter_joined_event(query, event_id),
    do: where(query, [_left, o], o.event_id == ^event_id)

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [o], o.status == ^status)

  defp maybe_filter_source_channel(query, nil), do: query

  defp maybe_filter_source_channel(query, source_channel),
    do: where(query, [o], o.source_channel == ^source_channel)

  defp maybe_filter_public_reference(query, nil), do: query
  defp maybe_filter_public_reference(query, :invalid), do: where(query, [o], false)

  defp maybe_filter_public_reference(query, search),
    do: where(query, [o], like(o.public_reference, ^"#{search}%"))

  defp maybe_filter_manual_review_only(query, true),
    do: where(query, [o], o.status == "manual_review")

  defp maybe_filter_manual_review_only(query, _), do: query

  defp maybe_filter_payment_status(query, nil), do: query

  defp maybe_filter_payment_status(query, status) do
    matching_payment_orders =
      from p in "sales_payment_attempts",
        where: p.status == ^status,
        select: p.sales_order_id

    where(query, [o], o.id in subquery(matching_payment_orders))
  end

  defp limit(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> clamp(1, @max_limit)
  end

  defp clamp(value, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp clamp(_value, min, _max), do: min

  defp parse_optional_integer(value) do
    case parse_integer(value) do
      {:ok, int} -> int
      _ -> nil
    end
  end

  defp parse_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid}
    end
  end

  defp parse_integer(_), do: {:error, :invalid}

  defp parse_date(value) when is_binary(value) and value != "" do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(%Date{} = date), do: date
  defp parse_date(_), do: nil

  defp clean_allowed(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" or not String.match?(value, ~r/^[a-zA-Z0-9_:-]+$/) do
      nil
    else
      value
    end
  end

  defp clean_allowed(_), do: nil

  defp clean_search(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      not String.match?(value, ~r/^[A-Za-z0-9_-]+$/) -> :invalid
      true -> value
    end
  end

  defp clean_search(_), do: nil

  defp truthy?(value) when value in [true, "true", "1", "on"], do: true
  defp truthy?(_), do: false

  defp mask_email(nil), do: nil
  defp mask_email(""), do: nil

  defp mask_email(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] ->
        "#{String.first(local) || "*"}***@#{domain}"

      _ ->
        "[masked]"
    end
  end

  defp mask_phone(nil), do: nil
  defp mask_phone(""), do: nil

  defp mask_phone(phone) when is_binary(phone) do
    digits = String.replace(phone, ~r/\D/, "")

    if String.length(digits) >= 4 do
      "***" <> String.slice(digits, -4, 4)
    else
      "[masked]"
    end
  end
end
