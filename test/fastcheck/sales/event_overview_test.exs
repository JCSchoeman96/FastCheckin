defmodule FastCheck.Sales.EventOverviewTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Sales.AdminDashboard
  alias FastCheckWeb.SalesWebFixtures, as: Fixtures

  @raw_email "overview.buyer@example.com"
  @raw_phone "+27998887766"
  @raw_buyer_name "Overview Buyer Secret"
  @ticket_code "OVERVIEW-TICKET-SECRET"
  @access_code "OVERVIEW_ACCESS_SECRET"
  @authorization_url "https://checkout.paystack.test/pay/overview-secret"
  @source_reference "tickera-ref-secret-001"

  setup do
    event_a = Fixtures.insert_event!(%{name: "Overview Event A"})
    event_b = Fixtures.insert_event!(%{name: "Overview Event B"})

    insert_attendee!(event_a.id, %{
      source: "tickera",
      ticket_code: "T-A-1",
      scan_eligibility: "active",
      is_currently_inside: true,
      email: "tickera-a@secret.example",
      source_reference: @source_reference
    })

    insert_attendee!(event_a.id, %{
      source: "tickera",
      ticket_code: "T-A-2",
      scan_eligibility: "not_scannable"
    })

    insert_attendee!(event_a.id, %{
      source: "tickera",
      ticket_code: "T-A-3",
      scan_eligibility: "active"
    })

    insert_attendee!(event_a.id, %{
      source: "fastcheck_sales",
      ticket_code: "FC-A-1",
      scan_eligibility: "active",
      is_currently_inside: true
    })

    insert_attendee!(event_a.id, %{
      source: "fastcheck_sales",
      ticket_code: "FC-A-2",
      scan_eligibility: "not_scannable"
    })

    insert_attendee!(event_b.id, %{
      source: "tickera",
      ticket_code: "T-B-1",
      scan_eligibility: "active"
    })

    offer_id = insert_offer!(event_a.id)

    wa_paid_id = insert_sales_order!(event_a.id, "WA-PAID", "paid_verified", "whatsapp")
    wa_pending_id = insert_sales_order!(event_a.id, "WA-PEND", "awaiting_payment", "whatsapp")
    _admin_order_id = insert_sales_order!(event_a.id, "ADM-ONLY", "paid_verified", "admin")

    line_vip = insert_order_line!(wa_paid_id, offer_id, "VIP", "VIP Snapshot Name")
    line_ga = insert_order_line!(wa_pending_id, offer_id, "GA", "GA Snapshot Name")

    insert_ticket_issue!(wa_paid_id, line_vip, "issued", "OVERVIEW-TI-1", 1)
    insert_ticket_issue!(wa_paid_id, line_vip, "manual_review", "OVERVIEW-TI-2", 2)
    insert_ticket_issue!(wa_pending_id, line_ga, "pending", "OVERVIEW-TI-3", 1)

    %{
      event_a: event_a,
      event_b: event_b
    }
  end

  test "event_overview returns mixed-source aggregates for the event", %{event_a: event_a} do
    assert {:ok, overview} = AdminDashboard.event_overview(event_a.id)

    assert overview.event.id == event_a.id
    assert overview.event.name == "Overview Event A"
    assert overview.event.status == "active"
    assert overview.event.whatsapp_sales_enabled == false

    tickera = overview.attendees.tickera
    assert tickera.total == 3
    assert tickera.scannable == 2
    assert tickera.not_scannable == 1
    assert tickera.currently_inside == 1

    sales = overview.attendees.fastcheck_sales
    assert sales.total == 2
    assert sales.scannable == 1
    assert sales.not_scannable == 1
    assert sales.currently_inside == 1

    whatsapp = overview.whatsapp
    assert whatsapp.order_count == 2
    assert whatsapp.orders_by_status["paid_verified"] == 1
    assert whatsapp.orders_by_status["awaiting_payment"] == 1
    refute Map.has_key?(whatsapp.orders_by_status, "admin")

    assert whatsapp.ticket_issue_count == 3
    assert whatsapp.ticket_issues_by_status["issued"] == 1
    assert whatsapp.ticket_issues_by_status["manual_review"] == 1
    assert whatsapp.ticket_issues_by_status["pending"] == 1

    assert length(whatsapp.ticket_types) == 2

    vip =
      Enum.find(whatsapp.ticket_types, fn row ->
        row.ticket_type == "VIP" and row.offer_name == "VIP Snapshot Name"
      end)

    assert vip.total_ticket_issues == 2
    assert vip.issued == 1
    assert vip.other_statuses["manual_review"] == 1

    refute unsafe_value_present?(overview)
  end

  test "event_overview excludes other events", %{event_a: event_a, event_b: event_b} do
    assert {:ok, overview_a} = AdminDashboard.event_overview(event_a.id)
    assert {:ok, overview_b} = AdminDashboard.event_overview(event_b.id)

    assert overview_a.attendees.tickera.total == 3
    assert overview_b.attendees.tickera.total == 1
    assert overview_a.whatsapp.order_count == 2
    assert overview_b.whatsapp.order_count == 0
  end

  test "event_overview returns not_found for unknown event" do
    assert AdminDashboard.event_overview(9_999_999) == {:error, :not_found}
    assert AdminDashboard.event_overview("not-an-id") == {:error, :not_found}
  end

  defp unsafe_value_present?(term) do
    encoded = inspect(term)

    Enum.any?(
      [
        @raw_email,
        @raw_phone,
        @raw_buyer_name,
        @ticket_code,
        @access_code,
        @authorization_url,
        @source_reference,
        "tickera-a@secret"
      ],
      &String.contains?(encoded, &1)
    )
  end

  defp insert_attendee!(event_id, attrs) do
    defaults = %{
      event_id: event_id,
      first_name: "Hidden",
      last_name: "Guest",
      email: "hidden@example.com",
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
          ($1, 'Overview offer', 'General', 10000, 'ZAR', 100, 100, 4, true, 'whatsapp',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '30 days',
           1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [event_id]
      )

    id
  end

  defp insert_sales_order!(event_id, public_reference, status, source_channel) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, idempotency_key, inserted_at, updated_at)
        VALUES
          ($1, $2, $3, $4, $5, $6, $7, 10000, 'ZAR', $8,
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [
          public_reference,
          event_id,
          @raw_buyer_name,
          @raw_phone,
          @raw_email,
          source_channel,
          status,
          "overview-idem-#{public_reference}"
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
          ($1, $2, 1, $3, $4, 'Overview Event', 1, 10000, 10000,
           'ZAR', '{}', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, offer_id, ticket_type, offer_name_snapshot]
      )

    id
  end

  defp insert_ticket_issue!(order_id, line_id, status, ticket_code, sequence) do
    unique = System.unique_integer([:positive])

    Repo.query!(
      """
      INSERT INTO sales_ticket_issues
        (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
         qr_token_hash, delivery_token_hash, status, scanner_status, issued_at,
         inserted_at, updated_at)
      VALUES
        ($1, $2, $5, NULL, $3, $6, $7, $4, 'valid',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [
        order_id,
        line_id,
        ticket_code,
        status,
        sequence,
        "qr-hash-#{unique}",
        "delivery-hash-#{unique}"
      ]
    )
  end
end
