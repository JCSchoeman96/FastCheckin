defmodule FastCheck.Workers.SyncRunRecoveryWorker do
  @moduledoc false

  use Oban.Worker, queue: :sync_maintenance, max_attempts: 1

  alias FastCheck.Events.SyncRunRecovery

  @impl Oban.Worker
  def perform(_job), do: {:ok, SyncRunRecovery.recover_expired()}
end
