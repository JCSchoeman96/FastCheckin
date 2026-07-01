defmodule Mix.Tasks.Fastcheck.Sales.SeedWhatsappSandbox do
  @moduledoc """
  Creates or resets the WhatsApp checkout sandbox fixture.

      mix fastcheck.sales.seed_whatsapp_sandbox
      mix fastcheck.sales.seed_whatsapp_sandbox --reset
  """

  use Mix.Task

  alias FastCheck.Sales.SandboxFixtures

  @shortdoc "Seeds the WhatsApp checkout sandbox fixture"
  @switches [reset: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    summary =
      if Keyword.get(opts, :reset, false) do
        SandboxFixtures.reset_whatsapp_checkout_fixture!()
      else
        SandboxFixtures.ensure_whatsapp_checkout_fixture!()
      end

    Mix.shell().info("""
    WhatsApp checkout sandbox fixture ready
      event_id: #{summary.event_id}
      event_name: #{summary.event_name}
      scanner_login_code: #{summary.scanner_login_code}
      offer_id: #{summary.offer_id}
      offer_name: #{summary.offer_name}
      sales_channel: #{summary.sales_channel}
      configured_quantity: #{summary.configured_quantity}
    """)
  end
end
