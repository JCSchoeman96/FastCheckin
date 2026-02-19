Mix.Task.run("app.start")

alias FastCheck.Attendees.Attendee
alias FastCheck.Crypto
alias FastCheck.Events.Event
alias FastCheck.Repo

attendee_count =
  System.get_env("FASTCHECK_PERF_ATTENDEE_COUNT", "5000")
  |> String.to_integer()

event_name =
  System.get_env("FASTCHECK_PERF_EVENT_NAME") ||
    "Performance Seed #{Date.utc_today() |> Date.to_iso8601()}"

entrance_name = System.get_env("FASTCHECK_PERF_ENTRANCE", "Main")
site_url = System.get_env("FASTCHECK_PERF_SITE_URL", "https://example.com")

api_key = "perf-api-#{System.unique_integer([:positive])}"
{:ok, encrypted_api_key} = Crypto.encrypt(api_key)
{:ok, encrypted_mobile_secret} = Crypto.encrypt("scanner-secret")

{:ok, event} =
  %Event{}
  |> Event.changeset(%{
    name: event_name,
    site_url: site_url,
    tickera_site_url: site_url,
    tickera_api_key_encrypted: encrypted_api_key,
    tickera_api_key_last4: String.slice(api_key, -4, 4),
    mobile_access_secret_encrypted: encrypted_mobile_secret,
    entrance_name: entrance_name,
    status: "active"
  })
  |> Repo.insert()

now = DateTime.utc_now() |> DateTime.truncate(:second)

:rand.seed(:exsplus, {
  System.system_time(:second),
  System.unique_integer([:positive]),
  :erlang.phash2(self())
})

ticket_types = [
  {101, "General"},
  {102, "VIP"},
  {103, "Staff"},
  {104, "Media"}
]

build_row = fn index ->
  {ticket_type_id, ticket_type} = Enum.at(ticket_types, rem(index - 1, length(ticket_types)))

  allowed_checkins =
    case :rand.uniform(100) do
      n when n <= 80 -> 1
      n when n <= 95 -> 2
      _ -> 9999
    end

  payment_status =
    case :rand.uniform(100) do
      n when n <= 90 -> "completed"
      n when n <= 98 -> "pending"
      _ -> "refunded"
    end

  checked_in? = :rand.uniform(100) <= 35
  checked_out? = checked_in? and :rand.uniform(100) <= 45
  currently_inside? = checked_in? and not checked_out?

  checkins_used =
    cond do
      not checked_in? -> 0
      allowed_checkins == 9999 -> :rand.uniform(6)
      true -> min(allowed_checkins, :rand.uniform(max(allowed_checkins, 1)))
    end

  checkins_remaining =
    cond do
      allowed_checkins == 9999 -> 9999
      true -> max(allowed_checkins - checkins_used, 0)
    end

  checked_in_at =
    if checked_in?, do: DateTime.add(now, -:rand.uniform(86_400), :second), else: nil

  checked_out_at =
    if checked_out? and checked_in_at do
      DateTime.add(checked_in_at, :rand.uniform(7_200), :second)
    else
      nil
    end

  ticket_code = "PERF-#{event.id}-#{String.pad_leading(Integer.to_string(index), 5, "0")}"

  %{
    event_id: event.id,
    ticket_code: ticket_code,
    first_name: "Guest#{index}",
    last_name: "Perf",
    email: "guest#{index}@perf.example.com",
    ticket_type_id: ticket_type_id,
    ticket_type: ticket_type,
    allowed_checkins: allowed_checkins,
    checkins_remaining: checkins_remaining,
    payment_status: payment_status,
    custom_fields: %{"segment" => "launch_seed", "row" => index},
    checked_in_at: checked_in_at,
    checked_out_at: checked_out_at,
    last_checked_in_at: checked_in_at,
    last_checked_in_date: if(checked_in_at, do: DateTime.to_date(checked_in_at), else: nil),
    daily_scan_count: if(checked_in?, do: min(checkins_used, 10), else: 0),
    weekly_scan_count: if(checked_in?, do: min(checkins_used * 2, 20), else: 0),
    monthly_scan_count: if(checked_in?, do: min(checkins_used * 4, 40), else: 0),
    is_currently_inside: currently_inside?,
    last_entrance: if(checked_in?, do: entrance_name, else: nil),
    inserted_at: now,
    updated_at: now
  }
end

rows = Enum.map(1..attendee_count, build_row)

rows
|> Enum.chunk_every(1_000)
|> Enum.with_index(1)
|> Enum.each(fn {chunk, chunk_index} ->
  {inserted, _} = Repo.insert_all(Attendee, chunk, timeout: :infinity)
  IO.puts("Inserted chunk #{chunk_index} (#{inserted} attendees)")
end)

IO.puts("Seed complete: event_id=#{event.id}, attendees=#{attendee_count}")
