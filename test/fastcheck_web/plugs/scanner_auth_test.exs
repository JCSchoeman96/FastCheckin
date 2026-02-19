defmodule FastCheckWeb.Plugs.ScannerAuthTest do
  use FastCheckWeb.ConnCase, async: true

  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  @credential "scanner-password"

  setup do
    event = insert_event()
    %{event: event}
  end

  describe "scanner route protection" do
    test "redirects unauthenticated users to scanner login", %{conn: conn, event: event} do
      conn = get(conn, ~p"/scanner/#{event.id}")
      assert redirected_to(conn) == "/scanner/login?redirect_to=%2Fscanner%2F#{event.id}"
    end

    test "redirects and clears session when event_id does not match", %{conn: conn, event: event} do
      conn =
        conn
        |> init_test_session(%{
          scanner_authenticated: true,
          scanner_event_id: event.id + 1,
          scanner_event_name: event.name,
          scanner_operator_name: "Mismatch"
        })
        |> get(~p"/scanner/#{event.id}")

      assert redirected_to(conn) == "/scanner/login?redirect_to=%2Fscanner%2F#{event.id}"
      assert get_session(conn, :scanner_authenticated) == nil
      assert get_session(conn, :scanner_event_id) == nil
    end

    test "allows access for valid scanner session", %{conn: conn, event: event} do
      conn =
        conn
        |> init_test_session(%{
          scanner_authenticated: true,
          scanner_event_id: event.id,
          scanner_event_name: event.name,
          scanner_operator_name: "Door One"
        })
        |> get(~p"/scanner/#{event.id}")

      assert html_response(conn, 200) =~ "Scanner portal"
    end

    test "redirects when event is archived", %{conn: conn} do
      archived_event = insert_event(%{status: "archived", name: "Archived"})

      conn =
        conn
        |> init_test_session(%{
          scanner_authenticated: true,
          scanner_event_id: archived_event.id,
          scanner_event_name: archived_event.name,
          scanner_operator_name: "Door 3"
        })
        |> get(~p"/scanner/#{archived_event.id}")

      assert redirected_to(conn) == "/scanner/login?redirect_to=%2Fscanner%2F#{archived_event.id}"
    end
  end

  defp insert_event(attrs \\ %{}) do
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
