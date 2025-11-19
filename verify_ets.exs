alias FastCheck.{Events, Cache.EtsLayer}

# Ensure app is started
{:ok, _} = Application.ensure_all_started(:fastcheck)

IO.puts("App started. Checking ETS tables...")
stats = EtsLayer.stats()
IO.inspect(stats, label: "Initial Stats")

# Find an event
event = FastCheck.Repo.one(Ecto.Query.from(e in FastCheck.Events.Event, limit: 1))

if event do
  IO.puts("Found event #{event.id}. Warming cache...")
  Events.warm_event_cache(event)

  stats_warmed = EtsLayer.stats()
  IO.inspect(stats_warmed, label: "Stats after warmup")

  if stats_warmed.attendees > 0 do
    IO.puts("Attendees loaded successfully.")
  else
    IO.puts("No attendees loaded (maybe event has none).")
  end

  IO.puts("Invalidating cache...")
  :ok = EtsLayer.invalidate_attendees(event.id)
  :ok = EtsLayer.invalidate_entrances(event.id)

  stats_final = EtsLayer.stats()
  IO.inspect(stats_final, label: "Stats after invalidation")
else
  IO.puts("No event found in DB.")
end

IO.puts("Verification complete.")
