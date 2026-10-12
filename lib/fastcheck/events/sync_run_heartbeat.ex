defmodule FastCheck.Events.SyncRunHeartbeat do
  @moduledoc "Renews one worker's exact durable SyncRun lease."

  alias FastCheck.Events.{SyncRun, SyncState}

  @interval_ms 30_000

  @doc "Starts a heartbeat process linked to the calling sync worker."
  def start_link(event_id, run, authority_guard, opts \\ [])

  def start_link(event_id, run, authority_guard, opts)
      when is_integer(event_id) and is_function(authority_guard, 1) and is_list(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @interval_ms)
    notify = Keyword.get(opts, :notify, self())

    if is_integer(interval_ms) and interval_ms > 0 and is_pid(notify) do
      Task.start_link(fn -> loop(event_id, run, authority_guard, interval_ms, notify) end)
    else
      {:error, :invalid_options}
    end
  end

  def start_link(_event_id, _run, _authority_guard, _opts), do: {:error, :invalid_options}

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  def stop(_pid), do: :ok

  defp loop(event_id, run, authority_guard, interval_ms, notify) do
    Process.sleep(interval_ms)

    case renew(event_id, run, authority_guard) do
      {:ok, status} ->
        send(notify, {:sync_run_heartbeat, :renewed, status})
        loop(event_id, run, authority_guard, interval_ms, notify)

      {:error, :authority_revoked} ->
        _ = SyncRun.cancel(event_id, run.sync_run_id, run.owner_token, :authority_revoked)
        _ = SyncState.clear_state(event_id, run.sync_run_id, run.owner_token)
        send(notify, {:sync_run_heartbeat, :terminal, :authority_revoked})

      {:error, reason} ->
        send(notify, {:sync_run_heartbeat, :terminal, reason})
    end
  end

  defp renew(event_id, run, authority_guard) do
    with :ok <- check_authority(authority_guard, event_id),
         {:ok, renewed} <- SyncRun.renew_lease(event_id, run.sync_run_id, run.owner_token) do
      {:ok, renewed.status}
    end
  end

  defp check_authority(authority_guard, event_id) do
    case authority_guard.(event_id) do
      :ok -> :ok
      _ -> {:error, :authority_revoked}
    end
  rescue
    _ -> {:error, :authority_revoked}
  catch
    _, _ -> {:error, :authority_revoked}
  end
end
