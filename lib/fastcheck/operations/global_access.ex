defmodule FastCheck.Operations.GlobalAccess do
  @moduledoc """
  Resolves the server-owned identities allowed to view global operations health.

  This boundary intentionally accepts a username, not a browser actor map. Event
  grants are scoped to event pages and never participate in this decision.
  """

  @config_key :operations_global_access

  @spec allowed_usernames() :: [String.t()]
  def allowed_usernames do
    case Application.get_env(:fastcheck, @config_key, :missing) do
      :missing ->
        default_usernames()

      config when is_list(config) ->
        config
        |> Keyword.get(:allowed_usernames, nil)
        |> normalize_configured_usernames()

      config when is_map(config) ->
        config
        |> Map.get(:allowed_usernames, Map.get(config, "allowed_usernames"))
        |> normalize_configured_usernames()

      _ ->
        default_usernames()
    end
  end

  @spec authorized?(term()) :: boolean()
  def authorized?(username) when is_binary(username) do
    String.trim(username) in allowed_usernames()
  end

  def authorized?(_), do: false

  @doc "Returns whether the identity has a server-owned dashboard session username."
  @spec authorized_identity?(Plug.Conn.t()) :: boolean()
  def authorized_identity?(conn) do
    username = Plug.Conn.get_session(conn, :dashboard_username)
    current_user = Map.get(conn.assigns, :current_user)

    is_binary(username) and
      is_map(current_user) and
      Map.get(current_user, :username) == username and
      authorized?(username)
  rescue
    ArgumentError -> false
  end

  defp normalize_configured_usernames(value) when is_list(value) do
    usernames =
      value
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    usernames
  end

  defp normalize_configured_usernames(_value), do: []

  defp default_usernames do
    case Application.get_env(:fastcheck, :dashboard_auth, %{}) do
      %{username: username} when is_binary(username) and username != "" -> [username]
      %{"username" => username} when is_binary(username) and username != "" -> [username]
      _ -> []
    end
  end
end
