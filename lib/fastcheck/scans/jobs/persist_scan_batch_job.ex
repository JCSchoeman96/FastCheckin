defmodule FastCheck.Scans.Jobs.PersistScanBatchJob do
  @moduledoc """
  Persists acknowledged mobile scan results and projects accepted entries into
  legacy attendee state.
  """

  use Oban.Worker, queue: :scan_persistence, max_attempts: 10

  alias FastCheck.Scans.Persistence

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"results" => results}}) do
    case Persistence.persist_batch(results) do
      :ok -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
