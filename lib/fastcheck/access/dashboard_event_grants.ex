defmodule FastCheck.Access.DashboardEventGrants do
  @moduledoc """
  Queries and trusted-identity grant transitions for durable dashboard Event grants.

  Callers must verify dashboard identity through `FastCheck.Sales.DashboardAccess`
  before invoking transition functions that accept a verified username.
  """

  import Ecto.Query, only: [from: 2]

  alias FastCheck.Access.DashboardEventGrant
  alias FastCheck.Repo

  @active_grant_unique_index "dashboard_event_grants_active_identity_event_uidx"

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

  @doc """
  Atomically revokes the active grant for a verified dashboard identity and Event.

  Trusted callers must pass the exact configured dashboard username.
  """
  @spec revoke_active_for_verified_identity(String.t(), pos_integer()) ::
          {:ok, :revoked | :already_revoked, DashboardEventGrant.t()}
          | {:error, :not_found}
  def revoke_active_for_verified_identity(username, event_id)
      when is_binary(username) and is_integer(event_id) and event_id > 0 do
    if valid_identity?(username) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      revoke_query =
        from grant in DashboardEventGrant,
          where:
            grant.dashboard_identity == ^username and
              grant.event_id == ^event_id and
              grant.state == "active",
          select: grant

      case Repo.update_all(revoke_query,
             inc: [lock_version: 1],
             set: [state: "revoked", revoked_at: now, updated_at: now]
           ) do
        {1, [grant]} ->
          {:ok, :revoked, grant}

        {0, _} ->
          case fetch_latest_revoked_grant_for_identity_event(username, event_id) do
            %DashboardEventGrant{} = grant -> {:ok, :already_revoked, grant}
            nil -> {:error, :not_found}
          end

        _unexpected ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  def revoke_active_for_verified_identity(_username, _event_id), do: {:error, :not_found}

  @doc """
  Regrants dashboard Event access for a verified identity when revoked history exists.

  Does not create the first-ever grant for an Event; active rows are returned
  idempotently and inserts require prior revoked history.
  """
  @spec regrant_for_verified_identity(String.t(), pos_integer()) ::
          {:ok, DashboardEventGrant.t()} | {:error, :not_found}
  def regrant_for_verified_identity(username, event_id)
      when is_binary(username) and is_integer(event_id) and event_id > 0 do
    if valid_identity?(username) do
      case fetch_active_grant_for_identity_event(username, event_id) do
        %DashboardEventGrant{} = grant ->
          {:ok, grant}

        nil ->
          if revoked_history_exists?(username, event_id) do
            insert_new_active_grant(username, event_id)
          else
            {:error, :not_found}
          end
      end
    else
      {:error, :not_found}
    end
  end

  def regrant_for_verified_identity(_username, _event_id), do: {:error, :not_found}

  defp insert_new_active_grant(username, event_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset =
      DashboardEventGrant.changeset(%DashboardEventGrant{}, %{
        dashboard_identity: username,
        event_id: event_id,
        granted_at: now,
        granted_by: username
      })

    case Repo.insert(changeset) do
      {:ok, grant} ->
        {:ok, grant}

      {:error, %Ecto.Changeset{} = changeset} ->
        if active_grant_unique_conflict?(changeset) do
          case fetch_active_grant_for_identity_event(username, event_id) do
            %DashboardEventGrant{} = grant -> {:ok, grant}
            nil -> {:error, :not_found}
          end
        else
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  defp fetch_active_grant_for_identity_event(username, event_id) do
    Repo.one(
      from grant in DashboardEventGrant,
        where:
          grant.dashboard_identity == ^username and
            grant.event_id == ^event_id and
            grant.state == "active",
        limit: 1
    )
  end

  defp fetch_latest_revoked_grant_for_identity_event(username, event_id) do
    Repo.one(
      from grant in DashboardEventGrant,
        where:
          grant.dashboard_identity == ^username and
            grant.event_id == ^event_id and
            grant.state == "revoked",
        order_by: [desc: grant.revoked_at, desc: grant.id],
        limit: 1
    )
  end

  defp revoked_history_exists?(username, event_id) do
    Repo.exists?(
      from grant in DashboardEventGrant,
        where:
          grant.dashboard_identity == ^username and
            grant.event_id == ^event_id and
            grant.state == "revoked"
    )
  end

  defp active_grant_unique_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:event_id, {_message, meta}} ->
        Keyword.get(meta, :constraint_name) == @active_grant_unique_index

      _ ->
        false
    end)
  end

  defp valid_identity?(identity) when is_binary(identity) do
    String.valid?(identity) and String.trim(identity) != ""
  end

  defp valid_identity?(_identity), do: false
end
