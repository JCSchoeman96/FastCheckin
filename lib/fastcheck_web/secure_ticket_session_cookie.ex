defmodule FastCheckWeb.SecureTicketSessionCookie do
  @moduledoc """
  Signed HTTP cookie boundary for P1-E browser ticket sessions.

  The cookie carries only an opaque `browser_session_id`; ticket authority remains
  in Postgres (durable) and Redis (warm ephemeral bindings).
  """

  @cookie_name "_fastcheck_ticket_session"
  @signing_salt "ticket-browser-session:v1"
  @cookie_path "/t"

  @doc "Cookie name for `_fastcheck_ticket_session`."
  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie_name

  @doc "Cookie path scope (`/t`)."
  @spec cookie_path() :: String.t()
  def cookie_path, do: @cookie_path

  @doc "Signs an opaque browser session id for Set-Cookie."
  @spec sign(String.t()) :: String.t()
  def sign(browser_session_id) when is_binary(browser_session_id) do
    Phoenix.Token.sign(FastCheckWeb.Endpoint, @signing_salt, browser_session_id)
  end

  @doc "Verifies a signed cookie value, returning the opaque browser session id."
  @spec verify(String.t()) :: {:ok, String.t()} | {:error, :invalid}
  def verify(signed_value) when is_binary(signed_value) do
    case Phoenix.Token.verify(FastCheckWeb.Endpoint, @signing_salt, signed_value,
           max_age: :infinity
         ) do
      {:ok, browser_session_id} when is_binary(browser_session_id) ->
        {:ok, browser_session_id}

      {:error, _} ->
        {:error, :invalid}
    end
  end

  @doc """
  Plug-compatible cookie options for future P1E-C2 controllers.

  Session cookie (no `max_age`); `secure` is enabled in production.
  """
  @spec cookie_options() :: keyword()
  def cookie_options do
    [
      http_only: true,
      same_site: "Lax",
      path: @cookie_path,
      secure: secure_cookie?()
    ]
  end

  defp secure_cookie? do
    endpoint = Application.fetch_env!(:fastcheck, FastCheckWeb.Endpoint)
    Keyword.get(endpoint, :force_ssl) != nil
  end
end
