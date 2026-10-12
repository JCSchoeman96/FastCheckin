defmodule FastCheck.Workers.SyncRunRecoveryWorkerTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query
  import FastCheck.Fixtures

  alias FastCheck.Events.{SyncLog, SyncRun}
  alias FastCheck.Repo
  alias FastCheck.Workers.SyncRunRecoveryWorker

  test "perform returns an Oban success result and preserves the recovery report" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)

    Repo.update_all(
      from(log in SyncLog, where: log.id == ^run.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    parent = self()
    previous_request_fun = Application.get_env(:fastcheck, :tickera_request_fun)

    Application.put_env(:fastcheck, :tickera_request_fun, fn request ->
      send(parent, {:tickera_request, request})
      {:error, :unexpected_request}
    end)

    on_exit(fn ->
      if is_nil(previous_request_fun),
        do: Application.delete_env(:fastcheck, :tickera_request_fun),
        else: Application.put_env(:fastcheck, :tickera_request_fun, previous_request_fun)
    end)

    assert {:ok, %{recovered: 1, skipped: 0}} = SyncRunRecoveryWorker.perform(%Oban.Job{})

    failed = Repo.get!(SyncLog, run.id)
    assert failed.status == "failed"
    assert failed.error_message == "lease_expired"
    refute_received {:tickera_request, _request}
  end
end
