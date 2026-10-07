defmodule FastCheckWeb.SecureTicketPdfController do
  @moduledoc """
  Customer PDF download for session-authorized secure ticket views.

  Legacy bearer-path PDF downloads are rejected without resolution (P1E-F).
  """

  use FastCheckWeb, :controller

  alias FastCheck.Tickets.PdfTicket
  alias FastCheck.Tickets.PdfTicket.Document
  alias FastCheck.Tickets.PdfTicket.Error, as: PdfError
  alias FastCheckWeb.SecureTicketSessionAccess

  @failure "Ticket PDF is not available for download."

  def view(conn, %{"ticket_issue_id" => ticket_issue_id}) do
    case SecureTicketSessionAccess.resolve(conn, ticket_issue_id) do
      {:ok, artifact} ->
        case PdfTicket.generate(artifact) do
          {:ok, %Document{} = document} ->
            send_pdf(conn, document)

          {:error, %PdfError{}} ->
            send_failure(conn, 500)

          {:error, :invalid_artifact} ->
            send_failure(conn, 500)
        end

      {:rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> send_failure(429)

      {:error, reason} ->
        send_failure(conn, session_error_status(reason))
    end
  end

  def reject_legacy(conn, _params), do: send_failure(conn, 404)

  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"]
  # This response is a generated application/pdf attachment after current bearer-token validation.
  defp send_pdf(conn, %Document{} = document) do
    conn
    |> put_resp_content_type(document.content_type)
    |> put_resp_header("content-disposition", "attachment; filename=\"#{document.filename}\"")
    |> put_private_pdf_headers()
    |> send_resp(200, document.binary)
  end

  defp send_failure(conn, status) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_private_pdf_headers()
    |> send_resp(status, @failure)
  end

  defp put_private_pdf_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store, private")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp session_error_status(:not_found), do: 404
  defp session_error_status(:expired_link), do: 410
  defp session_error_status(:ticket_revoked), do: 410
  defp session_error_status(:ticket_not_ready), do: 409
  defp session_error_status(:ticket_not_scannable), do: 409
  defp session_error_status(:session_unavailable), do: 503
  defp session_error_status(_other), do: 404
end
