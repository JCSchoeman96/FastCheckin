defmodule FastCheckWeb.SyncAuthorityGuard do
  @moduledoc "Builds server-side authority guards for the non-default SyncRun runner."

  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Sales.DashboardAccess

  @doc "Returns a guard that revalidates the current dashboard identity and event grant."
  def dashboard(identity) do
    fn event_id ->
      with {:ok, actor} <- DashboardAccess.actor_for_identity(identity),
           true <- DashboardAccess.event_granted?(actor, event_id) do
        :ok
      else
        _ -> {:error, :authority_revoked}
      end
    end
  end

  @doc "Returns a guard scoped to one event authenticated by ScannerAuth."
  def scanner_portal(scoped_event_id) when is_integer(scoped_event_id) do
    fn event_id ->
      with true <- event_id == scoped_event_id,
           %Event{} = event <- Repo.get(Event, scoped_event_id),
           {:ok, _state} <- Events.can_check_in?(event) do
        :ok
      else
        _ -> {:error, :authority_revoked}
      end
    end
  end

  def scanner_portal(_) do
    fn _event_id -> {:error, :authority_revoked} end
  end
end
