defmodule Mix.Tasks.Fastcheck.Load.CleanupMobileEvent do
  @moduledoc """
  Removes mobile performance seed data from Postgres and Redis.

      mix fastcheck.load.cleanup_mobile_event
      mix fastcheck.load.cleanup_mobile_event --manifest performance/manifests/mobile-load-event.json
      mix fastcheck.load.cleanup_mobile_event --event-id 123 --flush-redis
  """

  use Mix.Task

  alias FastCheck.Load.MobileEventCleanup

  @shortdoc "Cleans seeded mobile performance events and related hot state"

  @switches [
    event_id: :integer,
    flush_redis: :boolean,
    manifest: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    result = MobileEventCleanup.cleanup!(opts)

    Mix.shell().info("""
    Cleaned mobile performance data
      event_ids: #{format_event_ids(result.event_ids)}
      events deleted: #{result.deleted.events}
      attendees deleted: #{result.deleted.attendees}
      check_ins deleted: #{result.deleted.check_ins}
      scan_attempts deleted: #{result.deleted.scan_attempts}
      mobile_idempotency_logs deleted: #{result.deleted.mobile_idempotency_logs}
      oban_jobs deleted: #{result.deleted.oban_jobs}
      redis strategy: #{result.redis.strategy}
      redis status: #{result.redis.status}
      redis keys deleted: #{result.redis.deleted_keys}
    """)
  end

  defp format_event_ids([]), do: "[]"
  defp format_event_ids(event_ids), do: Enum.join(event_ids, ", ")
end
