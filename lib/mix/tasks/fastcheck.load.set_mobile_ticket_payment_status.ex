defmodule Mix.Tasks.Fastcheck.Load.SetMobileTicketPaymentStatus do
  @moduledoc """
  Updates one attendee payment status for integration harness scenarios.

      mix fastcheck.load.set_mobile_ticket_payment_status --event-id 123 --ticket-code PERF-000001 --payment-status refunded
  """

  use Mix.Task

  alias FastCheck.Load.MobileIntegrationScenario

  @shortdoc "Set payment status for one mobile test ticket"

  @switches [
    event_id: :integer,
    ticket_code: :string,
    payment_status: :string
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
    payment_status = Keyword.get(opts, :payment_status)

    with :ok <- require_event_id(event_id),
         :ok <- require_ticket_code(ticket_code),
         :ok <- require_payment_status(payment_status),
         {:ok, result} <-
           MobileIntegrationScenario.set_ticket_payment_status(
             event_id,
             ticket_code,
             payment_status
           ) do
      Mix.shell().info("""
      Payment status scenario update
        event_id: #{event_id}
        ticket_code: #{result.attendee.ticket_code}
        attendee_id: #{result.attendee.id}
        changed: #{result.changed}
        payment_status: #{result.attendee.payment_status}
      """)
    else
      {:error, :not_found} ->
        Mix.raise("ticket not found for event #{event_id}: #{ticket_code}")

      {:error, reason} ->
        Mix.raise("unable to set payment status: #{inspect(reason)}")
    end
  end

  defp require_event_id(event_id) when is_integer(event_id) and event_id > 0, do: :ok
  defp require_event_id(_), do: {:error, :invalid_event_id}

  defp require_ticket_code(ticket_code)
       when is_binary(ticket_code) and byte_size(ticket_code) > 0,
       do: :ok

  defp require_ticket_code(_), do: {:error, :invalid_ticket_code}

  defp require_payment_status(payment_status)
       when is_binary(payment_status) and byte_size(payment_status) > 0,
       do: :ok

  defp require_payment_status(_), do: {:error, :invalid_payment_status}
end
