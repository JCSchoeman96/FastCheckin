defmodule FastCheckWeb.ScannerSessionControllerTest do
  use FastCheckWeb.ConnCase, async: true

  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  @credential "scanner-password"

  setup do
    event = insert_event(%{name: "Scanner Test Event"})
    %{event: event}
  end

  describe "GET /scanner/login" do
    test "renders scanner login page", %{conn: conn} do
      conn = get(conn, ~p"/scanner/login")
      assert html_response(conn, 200) =~ "Sign in to event scanner"
    end
  end

  describe "POST /scanner/login" do
    test "creates scanner session for valid credentials", %{conn: conn, event: event} do
      conn =
        post(conn, ~p"/scanner/login", %{
          "scanner_session" => %{
            "event_id" => Integer.to_string(event.id),
            "credential" => @credential,
            "operator_name" => "Door 1"
          }
        })

      assert redirected_to(conn) == "/scanner/#{event.id}?tab=camera"
      assert get_session(conn, :scanner_authenticated) == true
      assert get_session(conn, :scanner_event_id) == event.id
      assert get_session(conn, :scanner_event_name) == event.name
      assert get_session(conn, :scanner_operator_name) == "Door 1"
    end

    test "requires logout before switching locked scanner session to a different event", %{
      conn: conn,
      event: locked_event
    } do
      target_event = insert_event(%{name: "Second Event"})

      conn =
        conn
        |> init_test_session(%{
          scanner_authenticated: true,
          scanner_event_id: locked_event.id,
          scanner_event_name: locked_event.name,
          scanner_operator_name: "Locked Operator"
        })
        |> post(~p"/scanner/login", %{
          "scanner_session" => %{
            "event_id" => Integer.to_string(target_event.id),
            "credential" => @credential,
            "operator_name" => "New Operator"
          }
        })

      assert html_response(conn, 403) =~ "locked to Event ID #{locked_event.id}"
      assert get_session(conn, :scanner_authenticated) == true
      assert get_session(conn, :scanner_event_id) == locked_event.id
      assert get_session(conn, :scanner_operator_name) == "Locked Operator"
    end

    test "rejects invalid credential", %{conn: conn, event: event} do
      conn =
        post(conn, ~p"/scanner/login", %{
          "scanner_session" => %{
            "event_id" => event.id,
            "credential" => "wrong",
            "operator_name" => "Door 2"
          }
        })

      assert html_response(conn, 403) =~ "Event password is invalid"
      assert get_session(conn, :scanner_authenticated) == nil
    end

    test "rejects missing operator name", %{conn: conn, event: event} do
      conn =
        post(conn, ~p"/scanner/login", %{
          "scanner_session" => %{
            "event_id" => event.id,
            "credential" => @credential,
            "operator_name" => ""
          }
        })

      assert html_response(conn, 400) =~ "Operator name is required"
    end

    test "rejects non-existent event", %{conn: conn} do
      conn =
        post(conn, ~p"/scanner/login", %{
          "scanner_session" => %{
            "event_id" => "999999",
            "credential" => @credential,
            "operator_name" => "Door 2"
          }
        })

      assert html_response(conn, 404) =~ "does not exist"
    end

    test "rejects archived event", %{conn: conn} do
      event = insert_event(%{status: "archived", name: "Archived Event"})

      conn =
        post(conn, ~p"/scanner/login", %{
          "scanner_session" => %{
            "event_id" => event.id,
            "credential" => @credential,
            "operator_name" => "Door 2"
          }
        })

      assert html_response(conn, 403) =~ "archived"
    end
  end

  describe "POST /scanner/:event_id/operator" do
    test "updates operator name for locked scanner session", %{conn: conn, event: event} do
      conn =
        conn
        |> init_test_session(%{
          scanner_authenticated: true,
          scanner_event_id: event.id,
          scanner_event_name: event.name,
          scanner_operator_name: "Door 1"
        })
        |> post(~p"/scanner/#{event.id}/operator", %{
          "operator_name" => "Door 9",
          "redirect_to" => "/scanner/#{event.id}?tab=attendees"
        })

      assert redirected_to(conn) == "/scanner/#{event.id}?tab=attendees"
      assert get_session(conn, :scanner_operator_name) == "Door 9"
    end

    test "rejects blank operator name and keeps current operator", %{conn: conn, event: event} do
      conn =
        conn
        |> init_test_session(%{
          scanner_authenticated: true,
          scanner_event_id: event.id,
          scanner_event_name: event.name,
          scanner_operator_name: "Door 3"
        })
        |> post(~p"/scanner/#{event.id}/operator", %{
          "operator_name" => "   ",
          "redirect_to" => "/scanner/#{event.id}?tab=camera"
        })

      assert redirected_to(conn) == "/scanner/#{event.id}?tab=camera"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Operator name is required"
      assert get_session(conn, :scanner_operator_name) == "Door 3"
    end
  end

  describe "DELETE /scanner/logout" do
    test "clears only scanner session keys", %{conn: conn, event: event} do
      conn =
        conn
        |> init_test_session(%{
          scanner_authenticated: true,
          scanner_event_id: event.id,
          scanner_event_name: event.name,
          scanner_operator_name: "Door 3",
          dashboard_authenticated: true,
          dashboard_username: "admin"
        })
        |> delete(~p"/scanner/logout")

      assert redirected_to(conn) == ~p"/scanner/login"
      assert get_session(conn, :scanner_authenticated) == nil
      assert get_session(conn, :scanner_event_id) == nil
      assert get_session(conn, :scanner_event_name) == nil
      assert get_session(conn, :scanner_operator_name) == nil
      assert get_session(conn, :dashboard_authenticated) == true
      assert get_session(conn, :dashboard_username) == "admin"
    end
  end

  defp insert_event(attrs) do
    api_key = "api-key-#{System.unique_integer([:positive])}"
    {:ok, encrypted_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_secret} = Crypto.encrypt(@credential)

    default_attrs = %{
      name: "Event #{System.unique_integer([:positive])}",
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_secret,
      status: "active",
      entrance_name: "Main Entrance"
    }

    params = Map.merge(default_attrs, attrs)

    %Event{}
    |> Event.changeset(params)
    |> Repo.insert!()
  end
end
