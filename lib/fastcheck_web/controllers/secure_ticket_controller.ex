defmodule FastCheckWeb.SecureTicketController do
  @moduledoc """
  Public customer secure ticket page for Sales-issued tickets (VS-11).

  Access is possession-based via delivery bearer tokens. No dashboard or scanner
  session is required.
  """

  use FastCheckWeb, :controller

  alias FastCheck.Sales.TicketPage

  def show(conn, %{"token" => token}) do
    result = TicketPage.resolve(token)

    conn
    |> put_private_ticket_headers()
    |> put_status(http_status(result.state))
    |> render(:show, result: result, download_token: download_token(result, token))
  end

  def show(conn, _params) do
    result = TicketPage.resolve("")

    conn
    |> put_private_ticket_headers()
    |> put_status(:not_found)
    |> render(:show, result: result, download_token: nil)
  end

  defp put_private_ticket_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store, private")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp download_token(%{state: :valid}, token), do: token
  defp download_token(_result, _token), do: nil

  defp http_status(:not_found), do: :not_found
  defp http_status(:expired_link), do: :gone
  defp http_status(_state), do: :ok
end
