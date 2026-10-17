defmodule FastCheck.Access.DashboardEventGrants do
  @moduledoc """
  Read-only queries for durable dashboard Event grants.
  """

  import Ecto.Query, only: [from: 2]

  alias FastCheck.Access.DashboardEventGrant
  alias FastCheck.Repo

  @spec active_event_ids_for_identity(String.t()) :: [pos_integer()]
  def active_event_ids_for_identity(identity) do
    if valid_identity?(identity) do
      query =
        from grant in DashboardEventGrant,
          where:
            grant.dashboard_identity == ^identity and
              grant.state == "active",
          select: grant.event_id,
          order_by: [asc: grant.event_id]

      Repo.all(query)
    else
      []
    end
  end

  @spec active_grant_exists?(String.t(), pos_integer()) :: boolean()
  def active_grant_exists?(identity, event_id)
      when is_integer(event_id) and event_id > 0 do
    if valid_identity?(identity) do
      query =
        from grant in DashboardEventGrant,
          where:
            grant.dashboard_identity == ^identity and
              grant.event_id == ^event_id and
              grant.state == "active"

      Repo.exists?(query)
    else
      false
    end
  end

  def active_grant_exists?(_identity, _event_id), do: false

  defp valid_identity?(identity) when is_binary(identity) do
    String.valid?(identity) and String.trim(identity) != ""
  end

  defp valid_identity?(_identity), do: false
end
