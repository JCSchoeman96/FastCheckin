defmodule FastCheckWeb.ExportControllerTest do
  use FastCheckWeb.ConnCase, async: true

  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  describe "GET /export/check-ins/:event_id" do
    test "returns csv headers even when there are no check-ins", %{conn: conn} do
      event = insert_event!(%{name: "Empty Checkin Event"})

      conn =
        conn
        |> init_test_session(%{
          dashboard_authenticated: true,
          dashboard_username: "admin"
        })
        |> get(~p"/export/check-ins/#{event.id}")

      assert FastCheckWeb.ConnCase.response_content_type(conn, :csv)
      assert conn.status == 200

      assert conn.resp_body =~
               "Ticket Code,Attendee Name,Scanned At,Entrance,Operator,Status,Notes"

      assert get_resp_header(conn, "content-disposition") != []
      assert hd(get_resp_header(conn, "content-disposition")) =~ "Empty_Checkin_Event_check_ins_"
    end
  end

  defp insert_event!(attrs) do
    api_key = Map.get(attrs, :tickera_api_key, "tickera-api-key")
    mobile_secret = Map.get(attrs, :mobile_secret, "scanner-secret")
    {:ok, encrypted_api_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_mobile_secret} = Crypto.encrypt(mobile_secret)

    defaults = %{
      name: "Event #{System.unique_integer([:positive])}",
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_api_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_mobile_secret,
      status: "active",
      entrance_name: "Main Gate",
      location: "Main Venue"
    }

    params =
      defaults
      |> Map.merge(attrs)
      |> Map.delete(:tickera_api_key)
      |> Map.delete(:mobile_secret)

    %Event{}
    |> Event.changeset(params)
    |> Repo.insert!()
  end
end
