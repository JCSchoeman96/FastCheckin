defmodule FastCheckWeb.Plugs.BrowserAuth do
  @moduledoc """
  Protects browser routes with a lightweight dashboard authentication.

  The plug accepts either an existing authenticated session or HTTP Basic
  Auth credentials that match the configured dashboard username/password.
  When authentication fails, the user is redirected to the login page with
  a `redirect_to` parameter pointing back to the requested path.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Plug.BasicAuth
  alias Plug.Crypto

  use FastCheckWeb, :verified_routes

  @session_key :dashboard_authenticated
  @session_username_key :dashboard_username

  @doc false
  def init(opts), do: opts

  @doc """
  Ensures the connection is authenticated for dashboard access.

  Authentication succeeds when:
  * the session already contains the `@session_key` flag, or
  * the request provides valid HTTP Basic Auth credentials matching the
    configured dashboard credentials.

  On success, `:current_user` is assigned so downstream plugs and LiveViews
  can access the authenticated username. On failure, the request is
  redirected to the login page with a `redirect_to` return path.
  """
  def call(conn, _opts) do
    cond do
      authenticated_session?(conn) ->
        assign_current_user(conn)

      {:ok, username, password} <- credentials_from_header(conn),
        valid_credentials?(username, password) ->
        conn
        |> put_session(@session_key, true)
        |> put_session(@session_username_key, username)
        |> assign(:current_user, %{id: username, username: username})

      true ->
        conn
        |> redirect(to: login_redirect_path(conn))
        |> halt()
    end
  end

  defp authenticated_session?(conn) do
    get_session(conn, @session_key) == true
  end

  defp assign_current_user(conn) do
    username = get_session(conn, @session_username_key) || configured_credentials().username

    assign(conn, :current_user, %{id: username, username: username})
  end

  defp credentials_from_header(conn) do
    case BasicAuth.parse_basic_auth(conn) do
      {username, password} -> {:ok, username, password}
      :error -> :error
    end
  end

  defp valid_credentials?(username, password) when is_binary(username) and is_binary(password) do
    %{username: configured_username, password: configured_password} = configured_credentials()

    secure_compare(username, configured_username) and
      secure_compare(password, configured_password)
  end

  defp valid_credentials?(_, _), do: false

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    Crypto.secure_compare(left, right)
  end

  defp configured_credentials do
    Application.fetch_env!(:fastcheck, :dashboard_auth)
  end

  defp login_redirect_path(conn) do
    redirect_target =
      case conn.query_string do
        "" -> conn.request_path
        qs -> conn.request_path <> "?" <> qs
      end

    ~p"/login?redirect_to=#{URI.encode_www_form(redirect_target)}"
  end
end
