defmodule FastCheck.Tickets.IssuerMobileSyncTest do
  use FastCheckWeb.ConnCase, async: false

  import Ecto.Query
  import FastCheck.Fixtures

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Mobile.Token
  alias FastCheck.Repo
  alias FastCheck.Sales.Order
  alias FastCheck.Tickets.Issuer

  describe "issue_order/2 mobile sync visibility" do
    test "fresh multi-ticket issuance bumps event_sync_version once", %{conn: _conn} do
      %{event: event, order_id: order_id} = paid_order_fixture(quantity: 3)

      assert event_sync_version(event.id) == 0

      assert {:ok, %{status: :ticket_issued, attendee_count: 3}} = Issuer.issue_order(order_id)

      assert event_sync_version(event.id) == 1
    end

    test "already issued retry does not bump event_sync_version again", %{conn: _conn} do
      %{event: event, order_id: order_id} = paid_order_fixture(quantity: 2)

      assert {:ok, %{status: :ticket_issued}} = Issuer.issue_order(order_id)
      assert event_sync_version(event.id) == 1

      assert {:ok, %{status: :already_issued}} = Issuer.issue_order(order_id)
      assert event_sync_version(event.id) == 1
    end

    test "durable sync bump failure rolls back issuance", %{conn: _conn} do
      %{event: event, order_id: order_id} = paid_order_fixture(quantity: 2)

      assert {:error, {:mobile_sync_version_aggregation_failed, :forced_failure}} =
               Issuer.issue_order(order_id,
                 mobile_sync_version_aggregator:
                   FastCheck.Tickets.IssuerMobileSyncTest.FailingAggregator
               )

      assert event_sync_version(event.id) == 0
      assert attendee_count(order_id) == 0
      assert ticket_issue_count(order_id) == 0
      assert Repo.get!(Order, order_id).status == "paid_verified"
    end

    test "mobile sync returns issued sales attendees and unchanged response shape", %{conn: conn} do
      %{event: event, order_id: order_id} = paid_order_fixture(quantity: 2)

      assert {:ok, %{status: :ticket_issued}} = Issuer.issue_order(order_id)
      {:ok, token} = Token.issue_scanner_token(event.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/v1/mobile/attendees?limit=50")

      assert %{
               "data" => data,
               "error" => nil
             } = json_response(conn, 200)

      assert Enum.sort(Map.keys(data)) ==
               Enum.sort([
                 "server_time",
                 "attendees",
                 "invalidations",
                 "count",
                 "sync_type",
                 "next_cursor",
                 "invalidations_checkpoint",
                 "event_sync_version"
               ])

      assert data["event_sync_version"] == 1

      sales_ticket_codes = sales_ticket_codes(order_id)

      returned_sales_attendees =
        Enum.filter(data["attendees"], &(&1["ticket_code"] in sales_ticket_codes))

      assert length(returned_sales_attendees) == 2

      for attendee <- returned_sales_attendees do
        assert Enum.sort(Map.keys(attendee)) ==
                 Enum.sort([
                   "id",
                   "event_id",
                   "ticket_code",
                   "first_name",
                   "last_name",
                   "email",
                   "ticket_type",
                   "allowed_checkins",
                   "checkins_remaining",
                   "payment_status",
                   "is_currently_inside",
                   "checked_in_at",
                   "checked_out_at",
                   "updated_at"
                 ])

        refute Map.has_key?(attendee, "source")
        refute Map.has_key?(attendee, "source_reference")
        refute Map.has_key?(attendee, "sales_order_id")
        refute Map.has_key?(attendee, "sales_ticket_issue_id")
      end
    end
  end

  defp paid_order_fixture(opts) do
    event = create_event()
    quantity = Keyword.get(opts, :quantity, 1)
    unit_amount = Keyword.get(opts, :unit_amount_cents, 12_500)
    total = quantity * unit_amount

    offer_id = insert_offer!(event.id, unit_amount)
    order_id = insert_order!(event.id, "paid_verified", total)
    line_id = insert_order_line!(order_id, offer_id, quantity, unit_amount, total)
    insert_checkout_session!(order_id, "paid", quantity)
    insert_payment_attempt!(order_id, "verified_success", total)

    %{event: event, order_id: order_id, line_id: line_id, offer_id: offer_id}
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
        [event_id, "Issuer Mobile Sync Offer #{System.unique_integer([:positive])}", price_cents]
      )

    id
  end

  defp insert_order!(event_id, status, total_amount_cents) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, paid_at, lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer Name', '+27123456789', 'buyer@example.com', 'test',
           $3, $4, 'ZAR', now(), 1, now(), now())
        RETURNING id
        """,
        ["ORD-#{System.unique_integer([:positive])}", event_id, status, total_amount_cents]
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
          ($1, $2, 1, 'General Admission', 'General Admission', 'Issuer Event',
           $3, $4, $5, 'ZAR', '{}', now(), now())
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
      VALUES
        ($1, $2, $3, '{}', 1, now(), now())
      """,
      [order_id, status, quantity]
    )
  end

  defp insert_payment_attempt!(order_id, status, amount_cents) do
    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, status, amount_cents, currency,
         verification_attempt_count, verified_at, last_verified_at, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', $2, $3, $4, 'ZAR', 1, now(), now(), now(), now())
      """,
      [order_id, "PAY-#{System.unique_integer([:positive])}", status, amount_cents]
    )
  end

  defp event_sync_version(event_id) do
    Repo.one!(from(e in Event, where: e.id == ^event_id, select: e.event_sync_version))
  end

  defp attendee_count(order_id) do
    Repo.aggregate(
      from(a in Attendee,
        where: a.source == "fastcheck_sales" and a.sales_order_id == ^order_id
      ),
      :count
    )
  end

  defp ticket_issue_count(order_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id,
        select: count(t.id)
    )
  end

  defp sales_ticket_codes(order_id) do
    Repo.all(
      from(a in Attendee,
        where: a.source == "fastcheck_sales" and a.sales_order_id == ^order_id,
        select: a.ticket_code
      )
    )
  end

  defmodule FailingAggregator do
    def after_attendees_created(_event_id, _ticket_codes, _opts), do: {:error, :forced_failure}
  end
end
