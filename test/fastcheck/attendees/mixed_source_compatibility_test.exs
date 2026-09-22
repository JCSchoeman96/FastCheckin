defmodule FastCheck.Attendees.MixedSourceCompatibilityTest do
  @moduledoc """
  WH-H10 (#432): mixed Tickera and FastCheck Sales attendee compatibility under one Event.

  Scanner identity remains `event_id + ticket_code` for both origins; `source` is provenance only.

  Related invariants exercised elsewhere (run as part of WH-H10 verification):

  * `FastCheck.Attendees.OriginProtectionTest` — Tickera bulk upsert must not overwrite
    `fastcheck_sales` rows on the same event + ticket code; authoritative reconciliation
    invalidates missing Tickera rows only.
  * `FastCheckWeb.Mobile.SyncControllerTest` — mobile sync includes active `fastcheck_sales`
    attendees without serializing internal lineage fields.
  """

  use FastCheck.DataCase, async: true

  import Ecto.Query
  import FastCheck.Fixtures

  alias FastCheck.Attendees
  alias FastCheck.Attendees.{Attendee, Scan}
  alias FastCheck.Repo

  @tickera_ticket "TICKERA-MIXED-001"
  @sales_ticket "FC-MIXED-SALES-001"
  @sales_source_reference "sales:9001:42:1"

  setup do
    event = create_event()

    tickera =
      create_attendee(event, %{
        ticket_code: @tickera_ticket,
        source: "tickera",
        first_name: "Tickera",
        last_name: "Guest",
        email: "tickera-guest@example.com",
        payment_status: "completed",
        scan_eligibility: "active",
        allowed_checkins: 1,
        checkins_remaining: 1
      })

    sales =
      create_attendee(event, %{
        ticket_code: @sales_ticket,
        source: "fastcheck_sales",
        source_reference: @sales_source_reference,
        sales_order_id: 9001,
        sales_ticket_issue_id: System.unique_integer([:positive]),
        first_name: "Sales",
        last_name: "Buyer",
        email: "sales-buyer@example.com",
        payment_status: "completed",
        scan_eligibility: "active",
        allowed_checkins: 1,
        checkins_remaining: 1
      })

    %{event: event, tickera: tickera, sales: sales}
  end

  describe "mixed-source coexistence under one event" do
    test "both rows persist with distinct source values", %{
      event: event,
      tickera: tickera,
      sales: sales
    } do
      persisted =
        Repo.all(
          from a in Attendee,
            where: a.event_id == ^event.id,
            order_by: [asc: a.ticket_code]
        )

      assert length(persisted) == 2
      assert tickera.source == "tickera"
      assert sales.source == "fastcheck_sales"
      assert sales.source_reference == @sales_source_reference

      assert Enum.map(persisted, & &1.source) |> Enum.sort() == ["fastcheck_sales", "tickera"]

      listed_codes =
        Attendees.list_event_attendees(event.id)
        |> Enum.map(& &1.ticket_code)
        |> Enum.sort()

      assert listed_codes == [@sales_ticket, @tickera_ticket]
    end
  end

  describe "shared scanner authority" do
    test "both origins check in via Scan.check_in/4 without cross-mutating source or sibling state",
         %{
           event: event,
           tickera: tickera,
           sales: sales
         } do
      assert {:ok, scanned_tickera, "SUCCESS"} =
               Scan.check_in(event.id, @tickera_ticket, "Main", nil)

      tickera_after_tickera_scan = Repo.get!(Attendee, tickera.id)
      sales_after_tickera_scan = Repo.get!(Attendee, sales.id)

      assert scanned_tickera.id == tickera.id
      assert scanned_tickera.source == "tickera"
      assert tickera_after_tickera_scan.checkins_remaining == 0
      assert tickera_after_tickera_scan.source == "tickera"

      assert sales_after_tickera_scan.checkins_remaining == 1
      assert sales_after_tickera_scan.source == "fastcheck_sales"
      refute sales_after_tickera_scan.checked_in_at

      assert {:ok, scanned_sales, "SUCCESS"} =
               Scan.check_in(event.id, @sales_ticket, "Main", nil)

      sales_after_sales_scan = Repo.get!(Attendee, sales.id)
      tickera_after_sales_scan = Repo.get!(Attendee, tickera.id)

      assert scanned_sales.id == sales.id
      assert scanned_sales.source == "fastcheck_sales"
      assert sales_after_sales_scan.checkins_remaining == 0
      assert sales_after_sales_scan.source == "fastcheck_sales"

      assert tickera_after_sales_scan.checkins_remaining == 0
      assert tickera_after_sales_scan.source == "tickera"
    end
  end

  describe "search/read compatibility" do
    test "event-scoped search finds both origins by customer-safe fields", %{event: event} do
      assert [_] = Attendees.search_event_attendees(event.id, @tickera_ticket)
      assert [_] = Attendees.search_event_attendees(event.id, "Tickera")
      assert [_] = Attendees.search_event_attendees(event.id, @sales_ticket)
      assert [_] = Attendees.search_event_attendees(event.id, "sales-buyer@example.com")
    end
  end
end
