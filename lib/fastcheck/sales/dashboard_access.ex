defmodule FastCheck.Sales.DashboardAccess do
  @moduledoc """
  Resolves authenticated dashboard identities to server-configured Sales event grants.

  Dashboard adapters must use this module to construct Sales actors. Supplied
  `allowed_event_ids` values are never treated as authority by this boundary.
  """

  @type actor :: %{
          required(:id) => String.t(),
          required(:username) => String.t(),
          required(:user_id) => String.t(),
          required(:actor_type) => :admin,
          required(:allowed_event_ids) => [pos_integer()]
        }

  @spec actor_for_identity(term()) :: {:ok, actor()} | {:error, :unauthorized}
  def actor_for_identity(identity) do
    with true <- dashboard_identity?(identity),
         username when is_binary(username) <- identity_username(identity),
         %{username: ^username} = auth <- dashboard_auth() do
      {:ok,
       %{
         id: username,
         username: username,
         user_id: username,
         actor_type: :admin,
         allowed_event_ids: configured_event_ids(auth)
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Returns the current server-configured grant set for a verified dashboard actor."
  @spec allowed_event_ids(term()) :: [pos_integer()]
  def allowed_event_ids(%{actor_type: actor_type} = actor) when actor_type in [:admin, "admin"] do
    case actor_for_identity(identity_username(actor)) do
      {:ok, trusted_actor} -> trusted_actor.allowed_event_ids
      {:error, :unauthorized} -> []
    end
  end

  def allowed_event_ids(_actor), do: []

  @doc "Checks an event against the actor's current server-configured grants."
  @spec event_granted?(term(), term()) :: boolean()
  def event_granted?(actor, event_id) when is_integer(event_id) and event_id > 0 do
    event_id in allowed_event_ids(actor)
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

  defp configured_event_ids(%{allowed_event_ids: event_ids}) when is_list(event_ids) do
    event_ids
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp configured_event_ids(_auth), do: []
end
