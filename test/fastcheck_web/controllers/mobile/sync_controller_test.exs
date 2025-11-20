defmodule FastCheckWeb.Mobile.SyncControllerTest do
  use FastCheckWeb.ConnCase, async: true

  alias FastCheck.{Repo, Events.Event, Attendees.Attendee, Mobile.Token}

  setup do
    # Create test event
    event =
      %Event{
        name: "Sync Test Event",
        tickera_site_url: "https://sync.example.com",
        tickera_api_key_encrypted: "encrypted_key",
        status: "active"
      }
      |> Repo.insert!()

    # Create another event to test event isolation
    other_event =
      %Event{
        name: "Other Event",
        tickera_site_url: "https://other.example.com",
        tickera_api_key_encrypted: "encrypted_key2",
        status: "active"
      }
      |> Repo.insert!()

    # Create test attendees for the main event
    attendee1 =
      %Attendee{
        event_id: event.id,
        ticket_code: "TEST001",
        first_name: "John",
        last_name: "Doe",
        email: "john@example.com",
        payment_status: "paid",
        allowed_checkins: 1,
        checkins_remaining: 1
      }
      |> Repo.insert!()

    attendee2 =
      %Attendee{
        event_id: event.id,
        ticket_code: "TEST002",
        first_name: "Jane",
        last_name: "Smith",
        email: "jane@example.com",
        payment_status: "completed",
        allowed_checkins: 1,
        checkins_remaining: 1
      }
      |> Repo.insert!()

    # Create attendee with refunded payment status
    refunded_attendee =
      %Attendee{
        event_id: event.id,
        ticket_code: "REFUND001",
        first_name: "Refunded",
        last_name: "User",
        payment_status: "refunded",
        allowed_checkins: 1,
        checkins_remaining: 1
      }
      |> Repo.insert!()

    # Create attendee in other event (should not be accessible)
    _other_attendee =
      %Attendee{
        event_id: other_event.id,
        ticket_code: "OTHER001",
        first_name: "Other",
        last_name: "Person",
        payment_status: "paid",
        allowed_checkins: 1,
        checkins_remaining: 1
      }
      |> Repo.insert!()

    # Generate JWT token for the main event
    {:ok, token} = Token.issue_scanner_token(event.id)

    %{
      event: event,
      other_event: other_event,
      attendee1: attendee1,
      attendee2: attendee2,
      refunded_attendee: refunded_attendee,
      token: token
    }
  end

  describe "GET /api/mobile/attendees - sync down" do
    test "requires authentication (401 without token)", %{conn: conn} do
      conn = get(conn, ~p"/api/mobile/attendees")
      assert json_response(conn, 401)["error"] == "missing_authorization_header"
    end

    test "rejects invalid token with 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid-token")
        |> get(~p"/api/mobile/attendees")

      assert json_response(conn, 401)["error"] in ["invalid_signature", "malformed_token"]
    end

    test "returns all attendees for authenticated event (full sync)", %{
      conn: conn,
      token: token,
      attendee1: attendee1,
      attendee2: attendee2
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/mobile/attendees")

      assert %{
               "server_time" => server_time,
               "attendees" => attendees,
               "count" => count,
               "sync_type" => "full"
             } = json_response(conn, 200)

      assert is_binary(server_time)
      assert count >= 2
      # Should include both attendees (and the refunded one)
      ticket_codes = Enum.map(attendees, & &1["ticket_code"])
      assert attendee1.ticket_code in ticket_codes
      assert attendee2.ticket_code in ticket_codes
    end

    test "returns only attendees for the authenticated event (event isolation)", %{
      conn: conn,
      token: token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/mobile/attendees")

      assert %{"attendees" => attendees} = json_response(conn, 200)

      # Should not include OTHER001 from other event
      ticket_codes = Enum.map(attendees, & &1["ticket_code"])
      refute "OTHER001" in ticket_codes
    end

    test "attendee objects contain required fields", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/mobile/attendees")

      assert %{"attendees" => [first_attendee | _]} = json_response(conn, 200)

      # Verify all required fields are present
      assert Map.has_key?(first_attendee, "id")
      assert Map.has_key?(first_attendee, "event_id")
      assert Map.has_key?(first_attendee, "ticket_code")
      assert Map.has_key?(first_attendee, "first_name")
      assert Map.has_key?(first_attendee, "last_name")
      assert Map.has_key?(first_attendee, "payment_status")
      assert Map.has_key?(first_attendee, "allowed_checkins")
      assert Map.has_key?(first_attendee, "checkins_remaining")
      assert Map.has_key?(first_attendee, "is_currently_inside")
      assert Map.has_key?(first_attendee, "updated_at")
    end

    test "supports incremental sync with since parameter", %{
      conn: conn,
      token: token,
      attendee2: attendee2
    } do
      # Get current server time
      past_time = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

      # Update attendee2 so it's newer
      {:ok, _} =
        attendee2
        |> Ecto.Changeset.change(%{first_name: "Updated Jane"})
        |> Repo.update()

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/mobile/attendees?since=#{past_time}")

      assert %{"sync_type" => "incremental", "attendees" => attendees} =
               json_response(conn, 200)

      # Should include updated attendee
      assert length(attendees) >= 1
    end

    test "falls back to full sync on invalid since parameter", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/mobile/attendees?since=invalid-date")

      assert %{"sync_type" => "full"} = json_response(conn, 200)
    end
  end

  describe "POST /api/mobile/scans - batch upload" do
    test "requires authentication (401 without token)", %{conn: conn} do
      conn = post(conn, ~p"/api/mobile/scans", %{"scans" => []})
      assert json_response(conn, 401)["error"] == "missing_authorization_header"
    end

    test "successfully processes a valid check-in scan", %{conn: conn, token: token} do
      scans = [
        %{
          "idempotency_key" => "scan-123-abc",
          "ticket_code" => "TEST001",
          "direction" => "in",
          "scanned_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "entrance_name" => "Main Gate"
        }
      ]

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/mobile/scans", %{"scans" => scans})

      assert %{"results" => [result], "processed" => 1} = json_response(conn, 200)
      assert result["idempotency_key"] == "scan-123-abc"
      assert result["status"] == "success"
      assert result["message"] =~ "Check-in successful"
    end

    test "enforces idempotency - duplicate scan returns cached result", %{
      conn: conn,
      token: token
    } do
      scan = %{
        "idempotency_key" => "duplicate-key-456",
        "ticket_code" => "TEST002",
        "direction" => "in",
        "scanned_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      # First upload
      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/mobile/scans", %{"scans" => [scan]})

      assert %{"results" => [result1]} = json_response(conn1, 200)
      assert result1["status"] == "success"

      # Second upload with same idempotency key
      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/mobile/scans", %{"scans" => [scan]})

      assert %{"results" => [result2]} = json_response(conn2, 200)
      assert result2["status"] == "duplicate"
      assert result2["message"] =~ "Already processed"
    end

    test "rejects scan for refunded ticket (payment validation)", %{conn: conn, token: token} do
      scan = %{
        "idempotency_key" => "refund-scan-789",
        "ticket_code" => "REFUND001",
        "direction" => "in",
        "scanned_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/mobile/scans", %{"scans" => [scan]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "error"
      assert result["message"] =~ "Payment invalid"
      assert result["message"] =~ "refunded"
    end

    test "rejects scan for non-existent ticket", %{conn: conn, token: token} do
      scan = %{
        "idempotency_key" => "invalid-ticket-scan",
        "ticket_code" => "NONEXISTENT",
        "direction" => "in",
        "scanned_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/mobile/scans", %{"scans" => [scan]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "error"
      assert result["message"] =~ "Ticket not found"
    end

    test "processes multiple scans in a batch", %{conn: conn, token: token} do
      scans = [
        %{
          "idempotency_key" => "batch-1",
          "ticket_code" => "TEST001",
          "direction" => "in"
        },
        %{
          "idempotency_key" => "batch-2",
          "ticket_code" => "TEST002",
          "direction" => "in"
        }
      ]

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/mobile/scans", %{"scans" => scans})

      assert %{"results" => results, "processed" => 2} = json_response(conn, 200)
      assert length(results) == 2
      assert Enum.all?(results, &(&1["status"] == "success"))
    end

    test "validates required fields in scan", %{conn: conn, token: token} do
      # Missing ticket_code
      scan = %{
        "idempotency_key" => "missing-field",
        "direction" => "in"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/mobile/scans", %{"scans" => [scan]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "error"
      assert result["message"] =~ "ticket_code"
    end

    test "validates direction field", %{conn: conn, token: token} do
      scan = %{
        "idempotency_key" => "invalid-direction",
        "ticket_code" => "TEST001",
        "direction" => "sideways"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/mobile/scans", %{"scans" => [scan]})

      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "error"
      assert result["message"] =~ "Invalid direction"
    end

    test "returns 400 when scans array is missing", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/mobile/scans", %{})

      assert %{"error" => "invalid_request"} = json_response(conn, 400)
    end
  end

  describe "event isolation in batch upload" do
    test "scans are scoped to authenticated event only", %{
      conn: conn,
      token: token,
      other_event: other_event
    } do
      # Create an attendee in the other event
      other_attendee =
        %Attendee{
          event_id: other_event.id,
          ticket_code: "ISOLATED001",
          payment_status: "paid",
          allowed_checkins: 1,
          checkins_remaining: 1
        }
        |> Repo.insert!()

      # Try to scan the other event's attendee with our token
      scan = %{
        "idempotency_key" => "cross-event-scan",
        "ticket_code" => other_attendee.ticket_code,
        "direction" => "in"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> post(~p"/api/mobile/scans", %{"scans" => [scan]})

      # Should fail because ticket doesn't exist in authenticated event
      assert %{"results" => [result]} = json_response(conn, 200)
      assert result["status"] == "error"
      assert result["message"] =~ "Ticket not found"
    end
  end
end
