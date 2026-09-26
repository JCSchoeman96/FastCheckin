defmodule FastCheck.Events.ArchivedEventRemovalTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Attendees.{Attendee, CheckIn}
  alias FastCheck.Events
  alias FastCheck.Events.Cache
  alias FastCheck.Events.SyncLog
  alias FastCheck.Fixtures
  alias FastCheck.Mobile.MobileIdempotencyLog
  alias FastCheck.Repo
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheck.Scans.ScanAttempt

  defp archive!(event) do
    assert {:ok, _} = Events.archive_event(event.id)
    Repo.get!(FastCheck.Events.Event, event.id)
  end

  test "removes empty archived event and clears list cache visibility" do
    event = Fixtures.create_event(%{name: "Empty Archived"})
    archived = archive!(event)

    assert {:ok, %{id: id, name: "Empty Archived"}} = Events.remove_archived_event(archived.id)
    assert id == archived.id
    assert Repo.get(FastCheck.Events.Event, archived.id) == nil

    refute Enum.any?(Cache.list_events(), &(&1.id == archived.id))
  end

  test "rejects removal for active events" do
    event = Fixtures.create_event(%{status: "active"})

    assert {:error, :event_not_archived} = Events.remove_archived_event(event.id)
    assert Repo.get!(FastCheck.Events.Event, event.id)
  end

  test "returns not_found for missing events" do
    assert {:error, :not_found} = Events.remove_archived_event(99_999_991)
  end

  test "returns integrity_conflict when an untracked foreign key prevents deletion" do
    event = Fixtures.create_event()
    archived = archive!(event)

    Repo.query!("""
    CREATE TABLE h13_untracked_event_fk_test (
      event_id bigint NOT NULL REFERENCES events(id)
    )
    """)

    Repo.query!(
      "INSERT INTO h13_untracked_event_fk_test (event_id) VALUES ($1)",
      [archived.id]
    )

    assert {:error, :integrity_conflict} = Events.remove_archived_event(archived.id)
    assert Repo.get!(FastCheck.Events.Event, archived.id)
  end

  test "blocks when attendees exist and preserves child rows" do
    event = Fixtures.create_event()
    attendee = Fixtures.create_attendee(event)
    archived = archive!(event)

    assert {:error, {:dependencies_present, %{attendees: 1}}} =
             Events.remove_archived_event(archived.id)

    assert Repo.get!(FastCheck.Events.Event, archived.id)
    assert Repo.get!(Attendee, attendee.id)
  end

  test "blocks on scanner and history dependencies" do
    event = Fixtures.create_event()
    attendee = Fixtures.create_attendee(event)

    %CheckIn{}
    |> CheckIn.changeset(%{
      event_id: event.id,
      attendee_id: attendee.id,
      ticket_code: attendee.ticket_code,
      checked_in_at: DateTime.utc_now(),
      status: "success"
    })
    |> Repo.insert!()

    %ScanAttempt{}
    |> ScanAttempt.changeset(%{
      event_id: event.id,
      attendee_id: attendee.id,
      idempotency_key: "scan-#{System.unique_integer([:positive])}",
      ticket_code: attendee.ticket_code,
      direction: "in",
      status: "success",
      scanned_at: DateTime.utc_now(),
      processed_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    {:ok, _sync_log} = SyncLog.log_sync_start(event.id)

    %MobileIdempotencyLog{}
    |> MobileIdempotencyLog.changeset(%{
      event_id: event.id,
      idempotency_key: "mobile-#{System.unique_integer([:positive])}",
      ticket_code: attendee.ticket_code,
      result: "success",
      metadata: %{}
    })
    |> Repo.insert!()

    archived = archive!(event)

    assert {:error, {:dependencies_present, blockers}} =
             Events.remove_archived_event(archived.id)

    assert blockers.attendees == 1
    assert blockers.check_ins == 1
    assert blockers.scan_attempts == 1
    assert blockers.sync_logs == 1
    assert blockers.mobile_idempotency_log == 1
    assert Repo.get!(FastCheck.Events.Event, archived.id)
  end

  test "blocks when ticket offers exist" do
    event = Fixtures.create_event()
    _offer = SalesFixtures.insert_offer!(event_id: event.id, sales_channel: "admin")
    archived = archive!(event)

    assert {:error, {:dependencies_present, %{sales_ticket_offers: 1}}} =
             Events.remove_archived_event(archived.id)

    assert Repo.get!(FastCheck.Events.Event, archived.id)
  end

  test "blocks when sales orders exist and preserves downstream sales rows" do
    event = Fixtures.create_event()
    offer = SalesFixtures.insert_offer!(event_id: event.id, sales_channel: "admin")

    order_id = insert_sales_order!(event.id)

    line_id =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'GA', 'Snap', 'Event', 1, 100, 100, 'ZAR', '{}',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, offer.id]
      ).rows
      |> List.first()
      |> List.first()

    archived = archive!(event)

    assert {:error, {:dependencies_present, blockers}} =
             Events.remove_archived_event(archived.id)

    assert blockers.sales_orders == 1
    assert Repo.get!(FastCheck.Events.Event, archived.id)
    assert Repo.one!(from(l in "sales_order_lines", where: l.id == ^line_id, select: l.id))
  end

  test "blocks when durable scan persistence jobs are queued for the event" do
    event = Fixtures.create_event()
    archived = archive!(event)

    {:ok, _job} =
      FastCheck.Scans.Jobs.PersistScanBatchJob.new(%{
        "results" => [
          %{
            "event_id" => event.id,
            "idempotency_key" => "persist-#{System.unique_integer([:positive])}",
            "ticket_code" => "SCAN-1",
            "direction" => "in",
            "status" => "success"
          }
        ]
      })
      |> Oban.insert()

    assert {:error, {:dependencies_present, %{pending_scan_persistence_jobs: 1}}} =
             Events.remove_archived_event(archived.id)

    assert Repo.get!(FastCheck.Events.Event, archived.id)
  end

  test "ticket offer on archived event blocks removal; checkout cannot create orphan orders" do
    alias FastCheck.Sales.Checkout

    event = Fixtures.create_event(%{name: "H04 removal guard"})
    offer = SalesFixtures.insert_offer!(event_id: event.id, sales_channel: "whatsapp")
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)
    assert {:ok, _} = Events.archive_event(event.id)

    assert {:error, {:dependencies_present, %{sales_ticket_offers: 1}}} =
             Events.remove_archived_event(event.id)

    assert Repo.get!(FastCheck.Events.Event, event.id)

    input =
      SalesFixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        source_channel: "whatsapp"
      })

    assert {:error, :whatsapp_sales_disabled} =
             Checkout.start_checkout(input, SalesFixtures.customer_session_actor([event.id]))

    assert 0 ==
             Repo.aggregate(
               from(o in "sales_orders", where: o.event_id == ^event.id),
               :count
             )
  end

  test "does not delete child rows to satisfy removal" do
    event = Fixtures.create_event()
    attendee = Fixtures.create_attendee(event)
    archived = archive!(event)

    assert {:error, {:dependencies_present, _}} = Events.remove_archived_event(archived.id)
    assert Repo.aggregate(Attendee, :count, :id) == 1
    assert Repo.get!(Attendee, attendee.id)
  end

  defp insert_sales_order!(event_id) do
    FastCheck.SalesCheckoutFixtures.ensure_event_for_sales!(event_id)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, source_channel, status, total_amount_cents, currency,
           idempotency_key, inserted_at, updated_at)
        VALUES
          ($1, $2, 'test', 'draft', 100, 'ZAR', $3,
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [
          "ORD-#{System.unique_integer([:positive])}",
          event_id,
          "removal-idem-#{System.unique_integer([:positive])}"
        ]
      )

    id
  end
end
