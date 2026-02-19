defmodule FastCheck.Fixtures do
  @moduledoc """
  Test fixtures and seed data generators for integration tests.
  """

  alias FastCheck.{Repo, Events.Event, Attendees.Attendee, Crypto}

  @doc """
  Creates a test event with encrypted API key.
  """
  def create_event(attrs \\ %{}) do
    api_key = Map.get(attrs, :tickera_api_key, "test-api-key-1234")
    {:ok, encrypted} = Crypto.encrypt(api_key)
    mobile_access_code = Map.get(attrs, :mobile_access_code, "scanner-secret")
    {:ok, encrypted_mobile_secret} = Crypto.encrypt(mobile_access_code)

    default_attrs = %{
      name: "Test Event #{System.unique_integer([:positive])}",
      tickera_site_url: "https://test.example.com",
      tickera_api_key_encrypted: encrypted,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_mobile_secret,
      status: "active",
      entrance_name: "Main Gate",
      total_tickets: 0,
      checked_in_count: 0
    }

    params = Map.merge(default_attrs, attrs)

    %Event{}
    |> Event.changeset(params)
    |> Repo.insert!()
  end

  @doc """
  Creates a test attendee for an event.
  """
  def create_attendee(event, attrs \\ %{}) do
    default_attrs = %{
      event_id: event.id,
      ticket_code: "TICKET-#{System.unique_integer([:positive])}",
      first_name: "John",
      last_name: "Doe",
      email: "john.doe@example.com",
      ticket_type: "General Admission",
      allowed_checkins: 1,
      checkins_remaining: 1,
      payment_status: "completed"
    }

    params = Map.merge(default_attrs, attrs)

    %Attendee{}
    |> Attendee.changeset(params)
    |> Repo.insert!()
  end

  @doc """
  Generates mock Tickera API response for event essentials.
  """
  def mock_event_essentials_response do
    %{
      "event_name" => "Test Event",
      "event_date_time" => "15th January 2025 19:00",
      "event_location" => "Test Venue",
      "sold_tickets" => 100,
      "checked_tickets" => 0,
      "pass" => true
    }
  end

  @doc """
  Generates mock Tickera API response for tickets_info (first page).
  """
  def mock_tickets_info_response(page \\ 1, per_page \\ 50, total_count \\ 100) do
    start_idx = (page - 1) * per_page + 1
    end_idx = min(start_idx + per_page - 1, total_count)

    data =
      start_idx..end_idx
      |> Enum.map(fn i ->
        %{
          "checksum" => "TICKET-#{i}",
          "buyer_first" => "Attendee#{i}",
          "buyer_last" => "Test#{i}",
          "payment_date" => "1st Jan 2025 - 10:00 am",
          "transaction_id" => "#{1000 + i}",
          "allowed_checkins" => 1,
          "custom_fields" => [
            ["Ticket Type", "General Admission"],
            ["Buyer E-mail", "attendee#{i}@example.com"],
            ["Company", "Test Company #{i}"]
          ]
        }
      end)

    %{
      "data" => data,
      "additional" => %{
        "results_count" => total_count
      }
    }
  end

  @doc """
  Generates mock Tickera API response for check_credentials.
  """
  def mock_check_credentials_response(valid \\ true) do
    if valid do
      %{
        "pass" => true,
        "license_key" => "TEST-LICENSE-KEY",
        "admin_email" => "admin@example.com",
        "tc_iw_is_pr" => true
      }
    else
      %{"pass" => false}
    end
  end
end
