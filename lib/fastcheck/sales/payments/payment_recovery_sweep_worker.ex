defmodule FastCheck.Sales.Payments.PaymentRecoverySweepWorker do
  @moduledoc """
  Periodically re-enqueues stale payment records through the existing payment workers.

  This worker does not contact Paystack. `PaymentVerification` remains the
  authority for all provider results.
  """

  use Oban.Worker,
    queue: :sales_maintenance,
    max_attempts: 5,
    unique: [period: 60, fields: [:args, :queue, :worker]]

  alias FastCheck.Sales.Payments.PaymentRecovery

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case PaymentRecovery.sweep() do
      {:ok, _counts} -> :ok
      {:error, _reason} -> {:error, :payment_recovery_enqueue_failed}
    end
  end
end
