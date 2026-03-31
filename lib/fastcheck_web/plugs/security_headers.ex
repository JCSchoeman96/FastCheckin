defmodule FastCheckWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Adds security headers including Content Security Policy (CSP) to all responses.

  CSP helps prevent XSS attacks by controlling which resources can be loaded.
  LiveView requires 'unsafe-inline' and 'unsafe-eval' for its JavaScript.
  """

  import Plug.Conn

  @content_security_policy [
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

  @browser_secure_headers %{
    "content-security-policy" => @content_security_policy,
    "x-content-type-options" => "nosniff",
    "x-frame-options" => "DENY",
    "x-xss-protection" => "1; mode=block",
    "referrer-policy" => "strict-origin-when-cross-origin"
  }

  @doc false
  def init(opts), do: opts

  @doc """
  Shared browser security headers for router and endpoint use.
  """
  def browser_secure_headers, do: @browser_secure_headers

  @doc """
  Shared browser CSP value for Phoenix router secure-browser headers.
  """
  def browser_content_security_policy, do: @content_security_policy

  @doc """
  Adds security headers to the connection response.
  """
  def call(conn, _opts) do
    conn
    |> put_shared_headers()
    |> put_resp_header("permissions-policy", "geolocation=(), microphone=(), camera=(self)")
  end

  defp put_shared_headers(conn) do
    Enum.reduce(browser_secure_headers(), conn, fn {header, value}, acc ->
      put_resp_header(acc, header, value)
    end)
  end
end
