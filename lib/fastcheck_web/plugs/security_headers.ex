defmodule FastCheckWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Adds security headers including Content Security Policy (CSP) to all responses.

  CSP helps prevent XSS attacks by controlling which resources can be loaded.
  LiveView requires 'unsafe-inline' and 'unsafe-eval' for its JavaScript.
  """

  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc """
  Adds security headers to the connection response.
  """
  def call(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", content_security_policy())
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("x-xss-protection", "1; mode=block")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header("permissions-policy", "geolocation=(), microphone=(), camera=()")
  end

  defp content_security_policy do
    [
      "default-src 'self'",
      # Required for LiveView
      "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
      # Required for TailwindCSS
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https:",
      "font-src 'self' data:",
      # WebSocket connections
      "connect-src 'self' wss: ws: https:",
      "frame-ancestors 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "upgrade-insecure-requests"
    ]
    |> Enum.join("; ")
  end
end
