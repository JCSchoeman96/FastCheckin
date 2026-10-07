defmodule FastCheckWeb.SecureTicketSessionAccess do
  @moduledoc """
  Shared P1E-D2 HTTP boundary for session-backed secure ticket HTML and PDF reads.

  Verifies the signed browser session cookie, applies distributed read rate limits,
  and delegates artifact authority to `TicketSessionReader` only.
  """

  alias FastCheck.Tickets.Artifact
  alias FastCheck.Tickets.TicketRateLimiter
  alias FastCheck.Tickets.TicketSessionReader
  alias FastCheckWeb.ClientIp
  alias FastCheckWeb.SecureTicketSessionCookie

  @type resolve_result ::
          {:ok, Artifact.t()}
          | {:error, TicketSessionReader.resolve_error()}
          | {:rate_limited, pos_integer()}

  @doc """
  Authorizes a session-backed ticket read for `ticket_issue_id` (route selector only).
  """
  @spec resolve(Plug.Conn.t(), String.t()) :: resolve_result()
  def resolve(conn, ticket_issue_id_param) when is_binary(ticket_issue_id_param) do
    with {:ok, browser_session_id} <- verified_browser_session_id(conn),
         {:ok, ticket_issue_id} <- parse_ticket_issue_id(ticket_issue_id_param),
         :ok <- apply_read_rate_limits(browser_session_id, ClientIp.from_conn(conn)),
         {:ok, artifact} <- TicketSessionReader.resolve(browser_session_id, ticket_issue_id) do
      {:ok, artifact}
    else
      {:error, :missing_cookie} -> {:error, :not_found}
      {:error, :invalid_cookie} -> {:error, :not_found}
      {:rate_limited, retry_after} -> {:rate_limited, retry_after}
      :rate_limit_unavailable -> {:error, :session_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verified_browser_session_id(conn) do
    case conn.req_cookies[SecureTicketSessionCookie.cookie_name()] do
      signed when is_binary(signed) ->
        case SecureTicketSessionCookie.verify(signed) do
          {:ok, browser_session_id} -> {:ok, browser_session_id}
          {:error, :invalid} -> {:error, :invalid_cookie}
        end

      _ ->
        {:error, :missing_cookie}
    end
  end

  defp parse_ticket_issue_id(param) do
    case Integer.parse(param) do
      {ticket_issue_id, ""} when ticket_issue_id > 0 -> {:ok, ticket_issue_id}
      _ -> {:error, :not_found}
    end
  end

  defp apply_read_rate_limits(browser_session_id, client_ip) do
    case TicketRateLimiter.check_session_read(browser_session_id, client_ip) do
      :allowed -> :ok
      {:rate_limited, retry_after} -> {:rate_limited, retry_after}
      :unavailable -> :rate_limit_unavailable
    end
  end
end
