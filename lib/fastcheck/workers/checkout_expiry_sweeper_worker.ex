defmodule FastCheck.Workers.CheckoutExpirySweeperWorker do
  @moduledoc """
  Oban cron worker that enqueues per-session checkout expiry jobs.

  Performs bounded candidate discovery only; all mutations happen in
  `FastCheck.Sales.CheckoutExpiry` via `CheckoutExpiryWorker`.
  """

  use Oban.Worker,
    queue: :sales_maintenance,
    max_attempts: 3,
    unique: [period: 120, fields: [:worker]]

  alias FastCheck.Sales.CheckoutExpiry

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    correlation_id = Map.get(args, "correlation_id")

    opts =
      [correlation_id: correlation_id]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    {:ok, _report} = CheckoutExpiry.sweep_and_enqueue(opts)
    :ok
  end
end
