defmodule FastCheck.Integration.EndToEndTest do
  @moduledoc """
  Comprehensive integration test that exercises the entire FastCheck flow:
  1. Create event with Tickera credentials
  2. Mock Tickera API responses
  3. Sync attendees from Tickera
  4. Scan tickets via LiveView
  5. Verify check-ins are recorded
  6. Test incremental sync
  7. Test export functionality
  """

  use FastCheckWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import FastCheck.Fixtures

  alias FastCheck.{Repo, Events, Attendees, Attendees.Attendee, Events.Event}

  @moduletag :integration

  setup %{conn: conn} do
    # Start Bypass for mocking HTTP requests
    bypass = Bypass.open()

    # Create test event pointing to Bypass server
    api_key = "test-api-key-#{System.unique_integer([:positive])}"
    {:ok, encrypted_key} = FastCheck.Crypto.encrypt(api_key)

    event =
      %Event{
        name: "Integration Test Event",
        tickera_site_url: "http://localhost:#{bypass.port}",
        tickera_api_key_encrypted: encrypted_key,
        tickera_api_key_last4: String.slice(api_key, -4, 4),
        status: "active",
        entrance_name: "Main Gate",
        total_tickets: 0,
        checked_in_count: 0
      }
      |> Repo.insert!()

    # Setup Bypass routes for Tickera API
    setup_bypass_routes(bypass, api_key)

    {:ok, conn: conn, event: event, bypass: bypass, api_key: api_key}
  end

  describe "Full end-to-end flow" do
    test "creates event, syncs attendees, scans tickets, and verifies results", %{
      conn: conn,
      event: event,
      bypass: bypass,
      api_key: api_key
    } do
      # Step 1: Verify event was created
      assert event.id > 0
      assert event.status == "active"

      # Step 2: Sync attendees from Tickera (mocked)
      assert {:ok, message} = Events.sync_event(event.id)
      assert message =~ "Synced"

      # Verify attendees were inserted
      attendees = Attendees.list_event_attendees(event.id)
      assert length(attendees) > 0

      # Get first attendee for scanning
      attendee = List.first(attendees)
      assert attendee.ticket_code
      assert attendee.checkins_remaining == 1
      assert is_nil(attendee.checked_in_at)

      # Step 3: Test scanning via LiveView
      {:ok, view, _html} =
        live(conn, ~p"/scan/#{event.id}")

      # Verify scanner page loaded
      assert has_element?(view, "h2", "Scan tickets")

      # Scan the ticket
      view
      |> form("form", %{ticket_code: attendee.ticket_code})
      |> render_submit()

      # Verify check-in succeeded
      refreshed_attendee = Repo.get!(Attendee, attendee.id)
      assert refreshed_attendee.checked_in_at
      assert refreshed_attendee.checkins_remaining == 0
      assert refreshed_attendee.is_currently_inside == true

      # Step 4: Verify stats updated
      stats = Attendees.get_event_stats(event.id)
      assert stats.checked_in_count > 0

      # Step 5: Test duplicate scan prevention
      view
      |> form("form", %{ticket_code: attendee.ticket_code})
      |> render_submit()

      # Should still be checked in only once
      final_attendee = Repo.get!(Attendee, attendee.id)
      assert final_attendee.checkins_remaining == 0

      # Step 6: Test incremental sync (should only sync new tickets)
      # Add more tickets to mock response - need to setup new Bypass expectations
      # For incremental sync, we'll add new tickets
      Bypass.expect_once(bypass, "GET", "/tc-api/#{api_key}/tickets_info/100/1/", fn conn ->
        # Return more tickets than before (add 10 new ones)
        response = mock_tickets_info_response(1, 100, 60)  # 60 total (50 existing + 10 new)
        Plug.Conn.resp(conn, 200, Jason.encode!(response))
      end)

      assert {:ok, incremental_message} = Events.sync_event(event.id, nil, incremental: true)
      assert incremental_message =~ "Incremental sync" || incremental_message =~ "new/updated"

      # Step 7: Test export functionality
      conn = get(conn, ~p"/export/attendees/#{event.id}")
      assert response_content_type(conn, :csv)
      assert conn.status == 200

      conn = get(conn, ~p"/export/check-ins/#{event.id}")
      assert response_content_type(conn, :csv)
      assert conn.status == 200
    end

    test "handles sync errors gracefully", %{event: event, bypass: bypass} do
      # Simulate API error
      Bypass.down(bypass)

      assert {:error, _reason} = Events.sync_event(event.id)

      # Verify event status is updated
      refreshed_event = Repo.get!(Event, event.id)
      assert refreshed_event.status == "error"
    end

    test "tests bulk entry mode", %{conn: conn, event: event} do
      # Create multiple attendees
      attendees =
        1..5
        |> Enum.map(fn i ->
          create_attendee(event, %{
            ticket_code: "BULK-#{i}",
            first_name: "Bulk#{i}",
            last_name: "Test#{i}"
          })
        end)

      {:ok, view, _html} = live(conn, ~p"/scan/#{event.id}")

      # Toggle bulk mode
      view
      |> element("button[phx-click='toggle_bulk_mode']")
      |> render_click()

      # Enter bulk codes
      codes = Enum.map(attendees, & &1.ticket_code) |> Enum.join("\n")

      view
      |> form("form", %{codes: codes})
      |> render_submit()

      # Verify all were checked in
      Enum.each(attendees, fn attendee ->
        refreshed = Repo.get!(Attendee, attendee.id)
        assert refreshed.checked_in_at
      end)
    end
  end

  # Helper functions

  defp setup_bypass_routes(bypass, api_key) do
    # Mock check_credentials endpoint
    Bypass.expect_once(bypass, "GET", "/tc-api/#{api_key}/check_credentials", fn conn ->
      response = mock_check_credentials_response(true)
      Plug.Conn.resp(conn, 200, Jason.encode!(response))
    end)

    # Mock event_essentials endpoint
    Bypass.expect_once(bypass, "GET", "/tc-api/#{api_key}/event_essentials", fn conn ->
      response = mock_event_essentials_response()
      Plug.Conn.resp(conn, 200, Jason.encode!(response))
    end)

    # Mock tickets_info endpoint (first page) - 100 per page to keep it simple
    Bypass.expect_once(bypass, "GET", "/tc-api/#{api_key}/tickets_info/100/1/", fn conn ->
      response = mock_tickets_info_response(1, 100, 50)  # 50 total tickets
      Plug.Conn.resp(conn, 200, Jason.encode!(response))
    end)
  end
end
