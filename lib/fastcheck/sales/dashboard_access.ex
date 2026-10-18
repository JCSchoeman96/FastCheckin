defmodule FastCheck.Sales.DashboardAccess do
  @moduledoc """
  Resolves authenticated dashboard identities to server-configured Sales event grants.

  Dashboard adapters must use this module to construct Sales actors. Supplied
  `allowed_event_ids` values are never treated as authority by this boundary.
  """

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

  @doc "Returns the current server-configured grant set for a verified dashboard actor."
  @spec allowed_event_ids(term()) :: [pos_integer()]
  def allowed_event_ids(%{actor_type: actor_type} = actor) when actor_type in [:admin, "admin"] do
    case verified_dashboard_identity(identity_username(actor)) do
      {:ok, username, auth} -> effective_event_ids(username, auth)
      :error -> []
    end
  end

  def allowed_event_ids(_actor), do: []

  @doc "Checks an event against the actor's current server-configured grants."
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
