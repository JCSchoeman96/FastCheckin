defmodule FastCheck.CheckIns.OfflineReconciliation do
  @moduledoc """
  Minimal reconciliation-state classifier for the scaffold.
  """

  @spec reconciliation_state(String.t()) :: String.t()
  def reconciliation_state("accepted_offline_pending"), do: "pending"
  def reconciliation_state("accepted_confirmed"), do: "confirmed"
  def reconciliation_state(_decision), do: "none"
end
