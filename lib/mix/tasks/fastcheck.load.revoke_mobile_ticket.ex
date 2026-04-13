defmodule Mix.Tasks.Fastcheck.Load.RevokeMobileTicket do
  @moduledoc """
  Marks a seeded attendee ticket as not_scannable for integration harness scenarios.

      mix fastcheck.load.revoke_mobile_ticket --event-id 123 --ticket-code PERF-000001
  """

  use Mix.Task

  alias FastCheck.Load.MobileIntegrationScenario

  @shortdoc "Revoke one mobile test ticket by code"

  @switches [
    event_id: :integer,
    ticket_code: :string,
    reason_code: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    event_id = Keyword.get(opts, :event_id)
    ticket_code = Keyword.get(opts, :ticket_code)
    reason_code = Keyword.get(opts, :reason_code)

    with :ok <- require_event_id(event_id),
         :ok <- require_ticket_code(ticket_code),
         {:ok, result} <-
           MobileIntegrationScenario.revoke_ticket(
             event_id,
             ticket_code,
             reason_code: reason_code
           ) do
      Mix.shell().info("""
      Revoke scenario update
        event_id: #{event_id}
        ticket_code: #{result.attendee.ticket_code}
        attendee_id: #{result.attendee.id}
        changed: #{result.changed}
        scan_eligibility: #{result.attendee.scan_eligibility}
      """)
    else
      {:error, :not_found} ->
        Mix.raise("ticket not found for event #{event_id}: #{ticket_code}")

      {:error, reason} ->
        Mix.raise("unable to revoke ticket: #{inspect(reason)}")
    end
  end

  defp require_event_id(event_id) when is_integer(event_id) and event_id > 0, do: :ok
  defp require_event_id(_), do: {:error, :invalid_event_id}

  defp require_ticket_code(ticket_code)
       when is_binary(ticket_code) and byte_size(ticket_code) > 0,
       do: :ok

  defp require_ticket_code(_), do: {:error, :invalid_ticket_code}
end
