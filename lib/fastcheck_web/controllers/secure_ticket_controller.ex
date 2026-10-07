defmodule FastCheckWeb.SecureTicketController do
  @moduledoc """
  Public customer secure ticket surfaces for Sales-issued tickets (VS-11).

  Fragment bootstrap and session-backed views are the active P1E paths. Legacy
  bearer-path HTML requests are hard-rejected without resolution (P1E-F).
  """

  use FastCheckWeb, :controller

  alias FastCheck.Sales.TicketPage
  alias FastCheckWeb.SecureTicketSessionAccess

  def bootstrap(conn, _params) do
    conn
    |> put_private_ticket_headers()
    |> render(:bootstrap)
  end

  def reject_legacy(conn, _params) do
    conn
    |> put_private_ticket_headers()
    |> put_status(:not_found)
    |> render(:show, result: TicketPage.from_session_error(:not_found), download_path: nil)
  end

  def view(conn, %{"ticket_issue_id" => ticket_issue_id}) do
    conn = put_private_ticket_headers(conn)

    case SecureTicketSessionAccess.resolve(conn, ticket_issue_id) do
      {:ok, artifact} ->
        result = TicketPage.from_artifact(artifact)

        conn
        |> put_status(:ok)
        |> render(:show,
          result: result,
          download_path: session_download_path(ticket_issue_id, result)
        )

      {:rate_limited, retry_after} ->
        conn
        |> put_status(:too_many_requests)
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> render(:show,
          result: TicketPage.from_session_error(:not_found),
          download_path: nil
        )

      {:error, :session_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> render(:show, result: service_unavailable_result(), download_path: nil)

      {:error, reason} ->
        result = TicketPage.from_session_error(reason)

        conn
        |> put_status(http_status(result.state))
        |> render(:show, result: result, download_path: nil)
    end
  end

  defp put_private_ticket_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store, private")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp session_download_path(ticket_issue_id, %{state: :valid}),
    do: "/t/view/#{ticket_issue_id}/pdf"

  defp session_download_path(_ticket_issue_id, _result), do: nil

  defp service_unavailable_result do
    %{
      state: :not_found,
      event_name: nil,
      attendee_name: nil,
      ticket_type: nil,
      qr_payload: nil,
      support_message: "Ticket service is temporarily unavailable."
    }
  end

  defp http_status(:not_found), do: :not_found
  defp http_status(:expired_link), do: :gone
  defp http_status(_state), do: :ok
end
