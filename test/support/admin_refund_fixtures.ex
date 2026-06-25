defmodule FastCheck.Sales.AdminRefundFixtures do
  @moduledoc false

  import Ecto.Query

  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Tickets.Issuer

  @dashboard_password "fastcheck"

  def dashboard_password, do: @dashboard_password

  def admin_actor(opts \\ []) do
    base = %{id: "admin", username: "admin", actor_type: :admin}

    case Keyword.get(opts, :event_id) do
      nil -> base
      event_id -> Map.put(base, :allowed_event_ids, [event_id])
    end
  end

  def operator_actor(opts \\ []) do
    base = %{id: "operator", username: "operator", actor_type: :operator}

    case Keyword.get(opts, :event_id) do
      nil -> base
      event_id -> Map.put(base, :allowed_event_ids, [event_id])
    end
  end

  def out_of_scope_admin_actor(in_scope_event_id) do
    admin_actor(event_id: in_scope_event_id + 999_999)
  end

  def admin_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "reason" => "Customer requested refund",
        "admin_password" => @dashboard_password,
        "confirmed_bulk" => "true",
        "idempotency_key" => "admin-#{System.unique_integer([:positive])}"
      },
      overrides
    )
  end

  def issued_order_fixture(opts \\ []) do
    quantity = Keyword.get(opts, :quantity, 1)
    event = Fixtures.create_event()
    unit_amount = 12_500
    total = quantity * unit_amount
    offer_id = insert_offer!(event.id, unit_amount)
    order_id = insert_order!(event.id, "paid_verified", total)
    line_id = insert_order_line!(order_id, offer_id, quantity, unit_amount, total)
    insert_checkout_session!(order_id, "paid", quantity)
    insert_payment_attempt!(order_id, "verified_success", total)

    case Issuer.issue_order(order_id) do
      {:ok, %{status: :ticket_issued}} -> :ok
      other -> raise "expected ticket_issued, got #{inspect(other)}"
    end

    order =
      Repo.one!(
        from o in "sales_orders", where: o.id == ^order_id, select: %{id: o.id, status: o.status}
      )

    if order.status != "ticket_issued" do
      raise "expected order ticket_issued, got #{order.status}"
    end

    %{
      event: event,
      order_id: order_id,
      line_id: line_id,
      ticket_issue_ids: ticket_issue_ids(order_id)
    }
  end

  def ticket_issue_ids(order_id) do
    Repo.all(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id,
        order_by: [asc: t.id],
        select: t.id
    )
  end

  def order_status(order_id) do
    Repo.one!(from o in "sales_orders", where: o.id == ^order_id, select: o.status)
  end

  def order_transition_count(order_id, to_state) do
    Repo.one!(
      from st in "sales_state_transitions",
        where:
          st.entity_type == "Order" and st.entity_id == ^to_string(order_id) and
            st.to_state == ^to_state,
        select: count(st.id)
    )
  end

  defp insert_offer!(event_id, price_cents) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'general', $3, 'ZAR', 100, 100, 10, true, 'whatsapp',
           now() - interval '1 day', now() + interval '30 days', 1, now(), now())
        RETURNING id
        """,
        [event_id, "Admin Refund Offer #{System.unique_integer([:positive])}", price_cents]
      )

    id
  end

  defp insert_order!(event_id, status, total_amount_cents) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer', '+27123456789', 'buyer@example.com', 'admin', $3, $4, 'ZAR', 1, now(), now())
        RETURNING id
        """,
        [
          "AR-#{System.unique_integer([:positive])}",
          event_id,
          status,
          total_amount_cents
        ]
      )

    id
  end

  defp insert_order_line!(order_id, offer_id, quantity, unit_amount, total_amount) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'general', 'Offer', 'Event', $3, $4, $5, 'ZAR', '{}', now(), now())
        RETURNING id
        """,
        [order_id, offer_id, quantity, unit_amount, total_amount]
      )

    id
  end

  defp insert_checkout_session!(order_id, status, quantity) do
    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, hold_quantity, state_data, lock_version, inserted_at, updated_at)
      VALUES ($1, $2, $3, '{}', 1, now(), now())
      """,
      [order_id, status, quantity]
    )
  end

  defp insert_payment_attempt!(order_id, status, amount_cents) do
    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, status, amount_cents, currency,
         verification_attempt_count, inserted_at, updated_at)
      VALUES ($1, 'paystack', $2, $3, $4, 'ZAR', 0, now(), now())
      """,
      [order_id, "ref-#{order_id}", status, amount_cents]
    )
  end
end
