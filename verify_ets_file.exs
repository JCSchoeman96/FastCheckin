alias FastCheck.{Events, Cache.EtsLayer}

# Ensure app is started
{:ok, _} = Application.ensure_all_started(:fastcheck)

File.write!("verification_results.log", "Starting verification...\n")

defmodule Verifier do
  def log(msg) do
    IO.puts(msg)
    File.write!("verification_results.log", "#{msg}\n", [:append])
  end
end

Verifier.log("App started. Checking ETS tables...")
stats = EtsLayer.stats()
Verifier.log("Initial Stats: #{inspect(stats)}")

# Find an event
event = FastCheck.Repo.one(Ecto.Query.from(e in FastCheck.Events.Event, limit: 1))

if event do
  Verifier.log("Found event #{event.id}. Warming cache...")
  Events.warm_event_cache(event)

  stats_warmed = EtsLayer.stats()
  Verifier.log("Stats after warmup: #{inspect(stats_warmed)}")

  if stats_warmed.attendees > 0 do
    Verifier.log("SUCCESS: Attendees loaded successfully.")
  else
    Verifier.log("WARNING: No attendees loaded (maybe event has none).")
  end

  Verifier.log("Invalidating cache...")
  :ok = EtsLayer.invalidate_attendees(event.id)
  :ok = EtsLayer.invalidate_entrances(event.id)

  stats_final = EtsLayer.stats()
  Verifier.log("Stats after invalidation: #{inspect(stats_final)}")
else
  Verifier.log("ERROR: No event found in DB.")
end

Verifier.log("Verification complete.")
