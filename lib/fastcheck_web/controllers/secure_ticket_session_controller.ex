defmodule FastCheckWeb.SecureTicketSessionController do
  @moduledoc """
  P1E-C2 browser exchange: fragment bearer in POST body → signed session cookie.
  """

  use FastCheckWeb, :controller

  alias FastCheck.Tickets.TicketExchange
  alias FastCheck.Tickets.TicketRateLimiter
  alias FastCheckWeb.ClientIp
  alias FastCheckWeb.SecureTicketSessionCookie

  def create(conn, _params) do
    conn = put_exchange_headers(conn)

    with :ok <- reject_query_delivery_token(conn),
         {:ok, delivery_token} <- body_delivery_token(conn),
         :ok <- apply_exchange_rate_limits(conn, delivery_token),
         {:ok, browser_session_id} <- existing_browser_session_id(conn),
         {:ok, %{browser_session_id: session_id, ticket_issue_id: ticket_issue_id}} <-
           TicketExchange.exchange(delivery_token, browser_session_id: browser_session_id) do
      conn
      |> put_resp_cookie(
        SecureTicketSessionCookie.cookie_name(),
        SecureTicketSessionCookie.sign(session_id),
        SecureTicketSessionCookie.cookie_options()
      )
      |> json(%{redirect_to: "/t/view/#{ticket_issue_id}"})
    else
      :missing_body_token ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "ticket_unavailable"})

      :query_token_forbidden ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "ticket_unavailable"})

      {:rate_limited, retry_after} ->
        conn
        |> put_status(:too_many_requests)
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> json(%{error: "rate_limited"})

      :rate_limit_unavailable ->
        conn |> put_status(:service_unavailable) |> json(%{error: "ticket_service_unavailable"})

      {:error, :session_unavailable} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "ticket_service_unavailable"})

      {:error, _reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "ticket_unavailable"})
    end
  end

  defp reject_query_delivery_token(conn) do
    if Map.has_key?(conn.query_params, "delivery_token") do
      :query_token_forbidden
    else
      :ok
    end
  end

  defp body_delivery_token(conn) do
    case conn.body_params do
      %{"delivery_token" => token} when is_binary(token) ->
        canonical = String.trim(token)

        if canonical == "" do
          :missing_body_token
        else
          {:ok, canonical}
        end

      _ ->
        :missing_body_token
    end
  end

  defp apply_exchange_rate_limits(conn, delivery_token) do
    client_ip = ClientIp.from_conn(conn)

    case TicketRateLimiter.check_exchange(delivery_token, client_ip) do
      :allowed -> :ok
      {:rate_limited, retry_after} -> {:rate_limited, retry_after}
      :unavailable -> :rate_limit_unavailable
    end
  end

  defp existing_browser_session_id(conn) do
    case conn.req_cookies[SecureTicketSessionCookie.cookie_name()] do
      signed when is_binary(signed) ->
        case SecureTicketSessionCookie.verify(signed) do
          {:ok, browser_session_id} -> {:ok, browser_session_id}
          {:error, :invalid} -> {:ok, nil}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp put_exchange_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
  end
end
