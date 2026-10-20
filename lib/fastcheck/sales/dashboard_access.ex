defmodule FastCheck.Sales.DashboardAccess do
  @moduledoc """
  Resolves dashboard identities verified against current server configuration
  to the union of configured bootstrap Event grants and active durable Postgres
  grants.

  Dashboard adapters must use this module to construct Sales actors. Supplied
  `allowed_event_ids` values are never treated as authority by this boundary.
  """

  alias FastCheck.Access.DashboardEventGrant
  alias FastCheck.Access.DashboardEventGrants

  @type actor :: %{
          required(:id) => String.t(),
          required(:username) => String.t(),
          required(:user_id) => String.t(),
          required(:actor_type) => :admin,
          required(:allowed_event_ids) => [pos_integer()]
        }

  @spec actor_for_identity(term()) :: {:ok, actor()} | {:error, :unauthorized}
  def actor_for_identity(identity) do
    case verified_dashboard_identity(identity) do
      {:ok, username, auth} ->
        {:ok, build_actor(username, effective_event_ids(username, auth))}

      :error ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Revalidates a dashboard identity against the current server configuration
  without resolving Event grants.
  """
  @spec revalidate_identity(term()) :: {:ok, String.t()} | {:error, :unauthorized}
  def revalidate_identity(identity) do
    case verified_dashboard_identity(identity) do
      {:ok, username, _auth} -> {:ok, username}
      :error -> {:error, :unauthorized}
    end
  end

  @doc """
  Revalidates a current dashboard identity and its Event-creation capability.
  """
  @spec revalidate_event_creation_authority(term()) ::
          {:ok, String.t()} | {:error, :unauthorized | :event_creation_disabled}
  def revalidate_event_creation_authority(identity) do
    case verified_dashboard_identity(identity) do
      {:ok, username, %{event_creation_enabled: true}} -> {:ok, username}
      {:ok, _username, _auth} -> {:error, :event_creation_disabled}
      :error -> {:error, :unauthorized}
    end
  end

  @doc """
  Returns the current effective union of configured and active durable Event
  grants for an actor whose identity still matches current dashboard configuration.
  """
  @spec allowed_event_ids(term()) :: [pos_integer()]
  def allowed_event_ids(%{actor_type: actor_type} = actor) when actor_type in [:admin, "admin"] do
    case verified_dashboard_identity(identity_username(actor)) do
      {:ok, username, auth} -> effective_event_ids(username, auth)
      :error -> []
    end
  end

  def allowed_event_ids(_actor), do: []

  @doc """
  Checks an Event against current configured or active durable authority for a
  dashboard actor whose identity still matches current server configuration.
  """
  @spec event_granted?(term(), term()) :: boolean()
  def event_granted?(%{actor_type: actor_type} = actor, event_id)
      when actor_type in [:admin, "admin"] and is_integer(event_id) and event_id > 0 do
    case verified_dashboard_identity(identity_username(actor)) do
      {:ok, username, auth} ->
        if event_id in configured_event_ids(auth) do
          true
        else
          active_grant_exists?(username, event_id)
        end

      :error ->
        false
    end
  end

  def event_granted?(_actor, _event_id), do: false

  @doc """
  Checks current exact Event authority for a verified dashboard identity.

  Configured Event IDs short-circuit the check. DB-only authority uses one exact
  indexed active-grant existence query.
  """
  @spec event_granted_for_identity?(term(), term()) :: boolean()
  def event_granted_for_identity?(identity, event_id)
      when is_integer(event_id) and event_id > 0 do
    case verified_dashboard_identity(identity) do
      {:ok, username, auth} ->
        if event_id in configured_event_ids(auth) do
          true
        else
          active_grant_exists?(username, event_id)
        end

      :error ->
        false
    end
  end

  def event_granted_for_identity?(_identity, _event_id), do: false

  @doc """
  Server-authorized durable grant revocation for the current trusted identity.

  Resolves effective access after commit using configured bootstrap grants plus
  any remaining active durable grant.
  """
  @spec revoke_event_grant(term(), pos_integer()) ::
          {:ok, %{status: :revoked | :already_revoked, effective_access: :granted | :denied}}
          | {:error, :unauthorized}
          | {:error, :not_found}
  def revoke_event_grant(identity, event_id) when is_integer(event_id) and event_id > 0 do
    with {:ok, username, _auth} <- verified_dashboard_identity(identity),
         {:ok, status, _grant} <-
           DashboardEventGrants.revoke_active_for_verified_identity(username, event_id) do
      effective_access =
        if event_granted_for_identity?(identity, event_id), do: :granted, else: :denied

      {:ok, %{status: status, effective_access: effective_access}}
    else
      :error -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def revoke_event_grant(_identity, _event_id), do: {:error, :not_found}

  @doc """
  Server-authorized durable grant regrant for the current trusted identity.

  Inserts a new active row only when revoked history exists for the identity and
  Event; it cannot create the first-ever grant for an arbitrary Event ID.
  """
  @spec regrant_event_grant(term(), pos_integer()) ::
          {:ok, DashboardEventGrant.t()}
          | {:error, :unauthorized}
          | {:error, :not_found}
  def regrant_event_grant(identity, event_id) when is_integer(event_id) and event_id > 0 do
    with {:ok, username, _auth} <- verified_dashboard_identity(identity),
         {:ok, grant} <- DashboardEventGrants.regrant_for_verified_identity(username, event_id) do
      {:ok, grant}
    else
      :error -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  def regrant_event_grant(_identity, _event_id), do: {:error, :not_found}

  defp identity_username(username) when is_binary(username), do: username

  defp identity_username(%{username: username}) when is_binary(username), do: username
  defp identity_username(%{"username" => username}) when is_binary(username), do: username
  defp identity_username(%{dashboard_username: username}) when is_binary(username), do: username

  defp identity_username(%{"dashboard_username" => username}) when is_binary(username),
    do: username

  defp identity_username(%{user_id: username}) when is_binary(username), do: username
  defp identity_username(%{"user_id" => username}) when is_binary(username), do: username

  defp identity_username(_identity), do: nil

  defp dashboard_identity?(identity) when is_map(identity) do
    case Map.get(identity, :actor_type, Map.get(identity, "actor_type")) do
      nil -> true
      actor_type when actor_type in [:admin, "admin"] -> true
      _ -> false
    end
  end

  defp dashboard_identity?(_identity), do: true

  defp dashboard_auth do
    Application.get_env(:fastcheck, :dashboard_auth, %{})
  end

  defp verified_dashboard_identity(identity) do
    with true <- dashboard_identity?(identity),
         username when is_binary(username) <- identity_username(identity),
         %{username: ^username} = auth <- dashboard_auth() do
      {:ok, username, auth}
    else
      _ -> :error
    end
  end

  defp build_actor(username, allowed_event_ids) do
    %{
      id: username,
      username: username,
      user_id: username,
      actor_type: :admin,
      allowed_event_ids: allowed_event_ids
    }
  end

  defp effective_event_ids(username, auth) do
    (configured_event_ids(auth) ++ active_event_ids(username))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp active_event_ids(username) do
    DashboardEventGrants.active_event_ids_for_identity(username)
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  defp active_grant_exists?(username, event_id) do
    DashboardEventGrants.active_grant_exists?(username, event_id)
  rescue
    DBConnection.ConnectionError -> false
    Postgrex.Error -> false
  end

  defp configured_event_ids(%{allowed_event_ids: event_ids}) when is_list(event_ids) do
    event_ids
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp configured_event_ids(_auth), do: []
end
