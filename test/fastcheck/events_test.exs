defmodule FastCheck.EventsTest do
  use FastCheck.DataCase, async: true

  alias Ecto.Changeset
  alias FastCheck.Events
  alias FastCheck.Events.{Event, CheckInConfiguration}
  alias FastCheck.Attendees.{Attendee, CheckIn}
  alias FastCheck.Cache.EtsLayer
  alias FastCheck.Repo

  describe "list_events/0" do
    test "returns attendee counts per event" do
      first_event = insert_event!("Summit")
      second_event = insert_event!("Expo")

      insert_attendees(first_event, 3)
      insert_attendees(second_event, 1)

      counts =
        Events.list_events()
        |> Enum.map(&{&1.id, &1.attendee_count})
        |> Map.new()

      assert counts[first_event.id] == 3
      assert counts[second_event.id] == 1
    end
  end

  describe "get_event_advanced_stats/1" do
    test "returns aggregated metrics" do
      event = insert_event!("Analytics")

      start_of_day = today_start_of_day()
      inside_check_in = DateTime.add(start_of_day, 3_600, :second)
      exit_time = DateTime.add(inside_check_in, 1_800, :second)

      attendee_inside =
        insert_attendee(%{
          event_id: event.id,
          checked_in_at: inside_check_in,
          last_checked_in_at: inside_check_in
        })

      insert_attendee(%{
        event_id: event.id,
        checked_in_at: inside_check_in,
        checked_out_at: exit_time,
        last_checked_in_at: inside_check_in
      })

      insert_attendee(%{event_id: event.id})

      %CheckInConfiguration{}
      |> CheckInConfiguration.changeset(%{
        event_id: event.id,
        ticket_type_id: 1,
        ticket_type: "GA",
        ticket_name: "General",
        allowed_checkins: 5,
        daily_check_in_limit: 10,
        time_basis: "daily",
        time_basis_timezone: "Etc/UTC"
      })
      |> Repo.insert!()

      insert_check_in!(event, attendee_inside, "North Gate", "entry", inside_check_in)
      insert_check_in!(event, attendee_inside, "North Gate", "exit", exit_time)
      insert_check_in!(event, attendee_inside, "South Gate", "success", inside_check_in)

      insert_check_in!(
        event,
        attendee_inside,
        "South Gate",
        "inside",
        DateTime.add(inside_check_in, 120, :second)
      )

      stats = Events.get_event_advanced_stats(event.id)

      assert stats.total_attendees == 3
      assert stats.checked_in == 2
      assert stats.pending == 1
      assert stats.currently_inside == 1
      assert stats.scans_today == 2
      assert stats.total_entries == 2
      assert stats.total_exits == 1
      assert stats.available_tomorrow == 8
      assert stats.average_session_duration_minutes == 30.0
      assert_in_delta stats.checked_in_percentage, 66.67, 0.01
      assert_in_delta stats.occupancy_percentage, 33.33, 0.01

      assert [%{} = info] = stats.time_basis_info
      assert info.ticket_type == "GA"
      assert info.daily_check_in_limit == 10

      north = Enum.find(stats.per_entrance, &(&1.entrance_name == "North Gate"))
      south = Enum.find(stats.per_entrance, &(&1.entrance_name == "South Gate"))

      assert north.entries == 1
      assert north.exits == 1
      assert north.inside == 0

      assert south.entries == 1
      assert south.exits == 0
      assert south.inside == 1
    end
  end

  describe "broadcast_occupancy_update/2" do
    test "broadcasts sanitized payload" do
      event = insert_event!("Arena")

      event =
        event
        |> Changeset.change(total_tickets: 200)
        |> Repo.update!()

      Phoenix.PubSub.subscribe(FastCheck.PubSub, "event:#{event.id}:occupancy")

      assert :ok = Events.broadcast_occupancy_update(event.id, 42)

      assert_receive {:occupancy_update, payload}
      assert payload.event_id == event.id
      assert payload.inside_count == 42
      assert payload.capacity == 200
      assert payload.percentage == 21.0
    end

    test "returns error when event is missing" do
      assert {:error, :event_not_found} = Events.broadcast_occupancy_update(123_456, 10)
      refute_receive {:occupancy_update, _payload}
    end
  end

  describe "warm_event_cache/1" do
    setup do
      EtsLayer.flush_all()
      on_exit(fn -> EtsLayer.flush_all() end)
      :ok
    end

    test "stores attendees and discovered entrances" do
      event = insert_event!("Cacheable")

      attendee =
        insert_attendee(%{
          event_id: event.id,
          last_entrance: "VIP Gate"
        })

      insert_check_in!(event, attendee, "South", "success", DateTime.utc_now())

      :ok = Events.warm_event_cache(event)

      assert {:ok, cached} = EtsLayer.get_attendee(event.id, attendee.ticket_code)
      assert cached.id == attendee.id

      entrances = EtsLayer.list_entrances(event.id)

      assert Enum.any?(entrances, &(&1.entrance_name == "VIP Gate"))
      assert Enum.any?(entrances, &(&1.entrance_name == "South"))
    end
  end

  defp insert_attendees(event, amount) do
    for _ <- 1..amount do
      attrs = %{
        event_id: event.id,
        ticket_code: unique_ticket_code(),
        first_name: "Attendee",
        last_name: "Example",
        email: "person-#{System.unique_integer([:positive])}@example.com"
      }

      %Attendee{}
      |> Attendee.changeset(attrs)
      |> Repo.insert!()
    end
  end

  defp insert_event!(name) do
    api_key = "key-#{System.unique_integer([:positive])}"
    {:ok, encrypted} = FastCheck.Crypto.encrypt(api_key)

    %Event{}
    |> Event.changeset(%{
      name: name,
      tickera_api_key_encrypted: encrypted,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      tickera_site_url: "https://example.com"
    })
    |> Repo.insert!()
  end

  defp insert_attendee(attrs) do
    defaults = %{
      ticket_code: unique_ticket_code(),
      first_name: "Attendee",
      last_name: "Example",
      email: "person-#{System.unique_integer([:positive])}@example.com",
      checkins_remaining: 1
    }

    %Attendee{}
    |> Attendee.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_check_in!(event, attendee, entrance, status, checked_in_at) do
    %CheckIn{}
    |> CheckIn.changeset(%{
      event_id: event.id,
      attendee_id: attendee.id,
      ticket_code: attendee.ticket_code,
      entrance_name: entrance,
      status: status,
      checked_in_at: checked_in_at
    })
    |> Repo.insert!()
  end

  defp unique_ticket_code do
    "CODE-#{System.unique_integer([:positive])}"
  end

  defp today_start_of_day do
    {:ok, start_of_day} = DateTime.new(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
    start_of_day
  end

  describe "Tickera credential helpers" do
    test "event changeset mirrors tickera_site_url into legacy site_url" do
      changeset =
        Event.changeset(%Event{}, %{
          name: "Compatibility",
          tickera_api_key_encrypted: "encrypted",
          mobile_access_secret_encrypted: "secret",
          tickera_site_url: "https://compat.example.com"
        })

      assert Changeset.get_field(changeset, :tickera_site_url) == "https://compat.example.com"
      assert Changeset.get_field(changeset, :site_url) == "https://compat.example.com"
    end

    test "set_tickera_credentials encrypts and returns struct" do
      api_key = "new-key-#{System.unique_integer([:positive])}"

      {:ok, cred_struct} =
        Events.set_tickera_credentials(
          %Event{},
          "https://demo.example.com",
          api_key,
          ~N[2024-01-01 10:00:00],
          ~N[2024-01-02 10:00:00]
        )

      assert cred_struct.tickera_site_url == "https://demo.example.com"
      assert cred_struct.site_url == "https://demo.example.com"
      assert cred_struct.status == "active"
      assert cred_struct.tickera_api_key_last4 == String.slice(api_key, -4, 4)
      assert {:ok, decrypted} = Events.get_tickera_api_key(cred_struct)
      assert decrypted == api_key
    end

    test "set_tickera_credentials updates persisted event" do
      event = insert_event!("Credentials")
      api_key = "rotated-#{System.unique_integer([:positive])}"

      {:ok, updated} =
        Events.set_tickera_credentials(event, "https://rotated.example.com", api_key, nil, nil)

      assert updated.tickera_site_url == "https://rotated.example.com"
      assert updated.site_url == "https://rotated.example.com"
      assert updated.tickera_api_key_last4 == String.slice(api_key, -4, 4)
      assert {:ok, decrypted} = Events.get_tickera_api_key(updated)
      assert decrypted == api_key
    end

    test "set_tickera_credentials normalizes surrounding whitespace" do
      raw_api_key = "  trimmed-key-#{System.unique_integer([:positive])} \n"
      expected_api_key = String.trim(raw_api_key)

      {:ok, cred_struct} =
        Events.set_tickera_credentials(
          %Event{},
          " https://demo.example.com ",
          raw_api_key,
          ~N[2024-01-01 10:00:00],
          ~N[2024-01-02 10:00:00]
        )

      assert cred_struct.tickera_site_url == "https://demo.example.com"
      assert cred_struct.site_url == "https://demo.example.com"
      assert cred_struct.tickera_api_key_last4 == String.slice(expected_api_key, -4, 4)
      assert {:ok, decrypted} = Events.get_tickera_api_key(cred_struct)
      assert decrypted == expected_api_key
    end

    test "touch_last_sync and touch_last_soft_sync update timestamps" do
      event = insert_event!("Timestamps")

      assert :ok = Events.touch_last_sync(event.id)
      assert :ok = Events.touch_last_soft_sync(event.id)

      refreshed = Repo.get!(Event, event.id)
      assert refreshed.last_sync_at
      assert refreshed.last_soft_sync_at
    end
  end
end
