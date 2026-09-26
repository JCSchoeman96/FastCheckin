defmodule FastCheckWeb.SecureTicketPdfController do
  @moduledoc """
  Customer PDF download for a currently valid secure ticket.

  Each request resolves the delivery token and current ticket eligibility before
  the renderer creates a transient PDF document.
  """

  use FastCheckWeb, :controller

  alias FastCheck.Tickets.ArtifactError
  alias FastCheck.Tickets.ArtifactResolver
  alias FastCheck.Tickets.PdfTicket
  alias FastCheck.Tickets.PdfTicket.Document
  alias FastCheck.Tickets.PdfTicket.Error, as: PdfError

  @failure "Ticket PDF is not available for download."

  def show(conn, %{"token" => token}) do
    with {:ok, artifact} <- ArtifactResolver.resolve_from_delivery_token(token),
         {:ok, %Document{} = document} <- PdfTicket.generate(artifact) do
      send_pdf(conn, document)
    else
      {:error, %ArtifactError{} = error} -> send_failure(conn, artifact_error_status(error))
      {:error, %PdfError{}} -> send_failure(conn, 500)
      {:error, :invalid_artifact} -> send_failure(conn, 500)
    end
  end

  def show(conn, _params), do: send_failure(conn, 404)

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

  defp artifact_error_status(%ArtifactError{state: :not_found}), do: 404
  defp artifact_error_status(%ArtifactError{state: :expired_link}), do: 410
  defp artifact_error_status(%ArtifactError{state: :ticket_revoked}), do: 410
  defp artifact_error_status(%ArtifactError{state: :ticket_not_ready}), do: 409
  defp artifact_error_status(%ArtifactError{state: :ticket_not_scannable}), do: 409
  defp artifact_error_status(%ArtifactError{}), do: 404
end
