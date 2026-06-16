defmodule FastCheck.Sales.Inventory.ReconciliationWorker do
  @moduledoc """
  Oban worker for scheduled or manual FastCheck Sales inventory reconciliation.

  Defaults to dry-run reconciliation. Explicit `mode: "repair"` with
  `allow_repair: true` is required for mutating recovery.
  """

  use Oban.Worker,
    queue: :sales_inventory,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:offer_id, :mode]]

  alias FastCheck.Sales.Inventory.Reconciler

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    offer_id = Map.fetch!(args, "offer_id")
    mode = Map.get(args, "mode", "dry_run")
    correlation_id = Map.get(args, "correlation_id")

    opts = [
      dry_run: mode != "repair",
      allow_repair: mode == "repair",
      correlation_id: correlation_id
    ]

    case Reconciler.reconcile_offer(offer_id, opts) do
      {:ok, _report} -> :ok
      {:manual_review_required, _report} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
