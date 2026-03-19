defmodule Mix.Tasks.Fastcheck.Load.SeedMobileEvent do
  @moduledoc """
  Seeds a deterministic mobile performance event and writes a k6 manifest.

      mix fastcheck.load.seed_mobile_event --attendees 5000 --credential scanner-secret
  """

  use Mix.Task

  alias FastCheck.Load.MobileEventSeed

  @shortdoc "Seeds a deterministic mobile performance event for k6"

  @switches [
    attendees: :integer,
    credential: :string,
    event_name: :string,
    output: :string,
    scanner_code: :string,
    ticket_prefix: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    result = MobileEventSeed.seed!(opts)

    Mix.shell().info("""
    Seeded mobile performance event
      event_id: #{result.event.id}
      scanner_login_code: #{result.event.scanner_login_code}
      manifest: #{result.manifest_path}
    """)
  end
end
