defmodule FastCheck.EventsCreateEventTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias Req.Response

  setup do
    previous_request_fun = Application.get_env(:fastcheck, :tickera_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:fastcheck, :tickera_request_fun)
      else
        Application.put_env(:fastcheck, :tickera_request_fun, previous_request_fun)
      end
    end)

    :ok
  end

  test "create_event/1 maps Tickera metadata and defaults" do
    mock_tickera_create_requests(%{
      "event_name" => "Voelgoed Live 2026",
      "event_date_time" => "2026-02-20T19:00:00Z",
      "event_location" => "Randburg Theatre",
      "sold_tickets" => 500,
      "checked_tickets" => 12,
      "pass" => true
    })

    assert {:ok, %Event{} = event} =
             Events.create_event(%{
               "tickera_site_url" => "https://voelgoed.co.za",
               "tickera_api_key_encrypted" => "api-key-12345",
               "mobile_access_code" => "scanner-secret"
             })

    assert event.name == "Voelgoed Live 2026"
    assert event.location == "Randburg Theatre"
    assert event.entrance_name == "Main Gate"
    assert event.total_tickets == 500
    assert event.checked_in_count == 12
    assert event.tickera_site_url == "https://voelgoed.co.za"
    assert event.event_date == ~D[2026-02-20]
    assert event.event_time == ~T[19:00:00]
  end

  test "create_event/1 treats blank overrides as missing and falls back to Tickera values" do
    mock_tickera_create_requests(%{
      "event_name" => "Auto Name Event",
      "event_date_time" => "2026-03-05T18:30:00Z",
      "event_location" => "Auto Venue",
      "sold_tickets" => 120,
      "checked_tickets" => 1,
      "pass" => true
    })

    assert {:ok, %Event{} = event} =
             Events.create_event(%{
               "tickera_site_url" => "https://voelgoed.co.za",
               "tickera_api_key_encrypted" => "api-key-blank-fallback",
               "mobile_access_code" => "scanner-secret",
               "name" => "   ",
               "location" => "   ",
               "entrance_name" => "   "
             })

    assert event.name == "Auto Name Event"
    assert event.location == "Auto Venue"
    assert event.entrance_name == "Main Gate"
    assert event.total_tickets == 120
    assert event.checked_in_count == 1
  end

  test "create_event/1 keeps location optional when Tickera omits event_location" do
    mock_tickera_create_requests(%{
      "event_name" => "No Location Event",
      "event_date_time" => "2026-04-01T17:00:00Z",
      "sold_tickets" => 90,
      "pass" => true
    })

    assert {:ok, %Event{} = event} =
             Events.create_event(%{
               "tickera_site_url" => "https://voelgoed.co.za",
               "tickera_api_key_encrypted" => "api-key-no-location",
               "mobile_access_code" => "scanner-secret"
             })

    assert event.name == "No Location Event"
    assert event.location in [nil, ""]
    assert event.entrance_name == "Main Gate"
    assert event.total_tickets == 90
    assert event.checked_in_count == 0
  end

  defp mock_tickera_create_requests(event_essentials) do
    Application.put_env(:fastcheck, :tickera_request_fun, fn req ->
      path = req.url.path || ""

      cond do
        String.ends_with?(path, "/check_credentials") ->
          {:ok, %Response{status: 200, body: %{"pass" => true}}}

        String.ends_with?(path, "/event_essentials") ->
          {:ok, %Response{status: 200, body: Map.put_new(event_essentials, "pass", true)}}

        true ->
          {:ok, %Response{status: 404, body: %{"error" => "not-found"}}}
      end
    end)
  end
end
