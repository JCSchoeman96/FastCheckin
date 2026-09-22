defmodule FastCheckWeb.Sales.EventOverviewLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheckWeb.SalesWebFixtures, as: Fixtures

  @raw_email "live.overview@example.com"
  @raw_phone "+27112223344"
  @ticket_code "LIVE-OVERVIEW-TICKET-SECRET"

  test "unauthenticated user is redirected" do
    event = Fixtures.insert_event!()
    conn = get(build_conn(), ~p"/dashboard/events/#{event.id}/overview")

    assert redirected_to(conn) ==
             "/login?redirect_to=%2Fdashboard%2Fevents%2F#{event.id}%2Foverview"
  end

  test "authenticated user sees mixed-source overview", %{conn: conn} do
    event = Fixtures.insert_event!(%{name: "Live Overview Event", whatsapp_sales_enabled: true})

    insert_attendee!(event.id, %{
      source: "tickera",
      ticket_code: "T-LIVE-1",
      scan_eligibility: "active"
    })

    insert_attendee!(event.id, %{
      source: "fastcheck_sales",
      ticket_code: "FC-LIVE-1",
      scan_eligibility: "active"
    })

    offer_id = insert_offer!(event.id)
    order_id = insert_sales_order!(event.id, "WA-LIVE", "paid_verified")
    line_id = insert_order_line!(order_id, offer_id, "VIP", "VIP Live Snapshot")
    insert_ticket_issue!(order_id, line_id, "issued")

    {:ok, _view, html} =
      conn
      |> Fixtures.authenticated_conn()
      |> live(~p"/dashboard/events/#{event.id}/overview")

    assert html =~ "Live Overview Event"
    assert html =~ "WordPress / Tickera"
    assert html =~ "WhatsApp / FastCheck"
    assert html =~ "FastCheck attendee rows"
    assert html =~ "Orders by status"
    assert html =~ "Ticket issues by status"
    assert html =~ "VIP Live Snapshot"
    assert html =~ "Paid verified"
    assert html =~ "Issued"
    refute_unsafe_html(html)
  end

  test "empty event shows understandable empty states", %{conn: conn} do
    event = Fixtures.insert_event!(%{name: "Empty Overview Event"})

    {:ok, _view, html} =
      conn
      |> Fixtures.authenticated_conn()
      |> live(~p"/dashboard/events/#{event.id}/overview")

    assert html =~ "No WordPress/Tickera attendees synced for this event."
    assert html =~ "No FastCheck-issued attendee rows for this event yet."
    assert html =~ "No WhatsApp/FastCheck orders for this event."
    assert html =~ "No WhatsApp ticket issues for this event."
    assert html =~ "No WhatsApp ticket-type activity yet."
    refute_unsafe_html(html)
  end

  test "unknown event redirects to dashboard without crash", %{conn: conn} do
    assert {:error,
            {:live_redirect, %{to: "/dashboard", flash: %{"error" => "Event not found."}}}} =
             conn
             |> Fixtures.authenticated_conn()
             |> live(~p"/dashboard/events/9999999/overview")
  end

  defp refute_unsafe_html(html) do
    for unsafe <- [@raw_email, @raw_phone, @ticket_code, "buyer@", "paystack"] do
      refute html =~ unsafe
    end
  end

  defp insert_attendee!(event_id, attrs) do
    defaults = %{
      event_id: event_id,
      first_name: "Hidden",
      last_name: "Guest",
      email: @raw_email,
      allowed_checkins: 1,
      checkins_remaining: 1,
      payment_status: "paid",
      is_currently_inside: false
    }

    %Attendee{}
    |> Attendee.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_offer!(event_id) do
    FastCheck.SalesCheckoutFixtures.ensure_event_for_sales!(event_id)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          ($1, 'Live offer', 'General', 10000, 'ZAR', 100, 100, 4, true, 'whatsapp',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '30 days',
           1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [event_id]
      )

    id
  end

  defp insert_sales_order!(event_id, public_reference, status) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, idempotency_key, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Secret Buyer', $3, $4, 'whatsapp', $5, 10000, 'ZAR', $6,
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [
          public_reference,
          event_id,
          @raw_phone,
          @raw_email,
          status,
          "live-overview-#{public_reference}"
        ]
      )

    id
  end

  defp insert_order_line!(order_id, offer_id, ticket_type, offer_name_snapshot) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, $3, $4, 'Live Event', 1, 10000, 10000,
           'ZAR', '{}', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, offer_id, ticket_type, offer_name_snapshot]
      )

    id
  end

  defp insert_ticket_issue!(order_id, line_id, status) do
    Repo.query!(
      """
      INSERT INTO sales_ticket_issues
        (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
         qr_token_hash, delivery_token_hash, status, scanner_status, issued_at,
         inserted_at, updated_at)
      VALUES
        ($1, $2, 1, NULL, $3, 'qr-live-secret', 'delivery-live-secret', $4, 'valid',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, line_id, @ticket_code, status]
    )
  end
end
