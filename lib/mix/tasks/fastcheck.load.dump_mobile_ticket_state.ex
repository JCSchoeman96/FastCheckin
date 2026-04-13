defmodule Mix.Tasks.Fastcheck.Load.DumpMobileTicketState do
  @moduledoc """
  Prints a JSON state snapshot for one mobile harness ticket.

      mix fastcheck.load.dump_mobile_ticket_state --event-id 123 --ticket-code PERF-000001
  """

  use Mix.Task

  alias FastCheck.Load.MobileIntegrationScenario

  @shortdoc "Dump mobile harness ticket state as JSON"

  @switches [
    event_id: :integer,
    ticket_code: :string,
    invalidation_limit: :integer
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
    invalidation_limit = Keyword.get(opts, :invalidation_limit, 5)

    with :ok <- require_event_id(event_id),
         :ok <- require_ticket_code(ticket_code),
         :ok <- require_invalidation_limit(invalidation_limit),
         {:ok, state_dump} <-
           MobileIntegrationScenario.dump_ticket_state(
             event_id,
             ticket_code,
             invalidation_limit: invalidation_limit
           ) do
      Mix.shell().info(Jason.encode_to_iodata!(state_dump, pretty: true))
    else
      {:error, :not_found} ->
        Mix.raise("ticket not found for event #{event_id}: #{ticket_code}")

      {:error, reason} ->
        Mix.raise("unable to dump ticket state: #{inspect(reason)}")
    end
  end

  defp require_event_id(event_id) when is_integer(event_id) and event_id > 0, do: :ok
  defp require_event_id(_), do: {:error, :invalid_event_id}

  defp require_ticket_code(ticket_code)
       when is_binary(ticket_code) and byte_size(ticket_code) > 0,
       do: :ok

  defp require_ticket_code(_), do: {:error, :invalid_ticket_code}

  defp require_invalidation_limit(limit) when is_integer(limit) and limit > 0, do: :ok
  defp require_invalidation_limit(_), do: {:error, :invalid_invalidation_limit}
end
