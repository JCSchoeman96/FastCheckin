defmodule FastCheckWeb.Sales.TicketPdfController do
  @moduledoc """
  Dashboard-only PDF ticket download for manual staff delivery.

  This controller does not create delivery attempts, send messages, store PDFs,
  or resolve public delivery tokens.
  """

  use FastCheckWeb, :controller

  alias FastCheck.Tickets.ArtifactError
  alias FastCheck.Tickets.ArtifactResolver
  alias FastCheck.Tickets.PdfTicket
  alias FastCheck.Tickets.PdfTicket.Document
  alias FastCheck.Tickets.PdfTicket.Error, as: PdfError

  @failure "Ticket PDF is not available for download."

  def show(conn, %{"ticket_issue_id" => ticket_issue_id}) do
    actor = dashboard_actor(conn)

    with {:ok, artifact} <-
           ArtifactResolver.resolve_for_admin_ticket_issue(actor, ticket_issue_id),
         {:ok, %Document{} = document} <- PdfTicket.generate(artifact) do
      send_pdf(conn, document)
    else
      {:error, %ArtifactError{} = error} -> send_failure(conn, artifact_error_status(error))
      {:error, %PdfError{}} -> send_failure(conn, 500)
      {:error, :invalid_artifact} -> send_failure(conn, 500)
      {:error, _reason} -> send_failure(conn, 409)
    end
  end

  defp dashboard_actor(conn) do
    current_user = conn.assigns[:current_user] || %{}

    username =
      Map.get(current_user, :username) || Map.get(current_user, "username") || "dashboard"

    id = Map.get(current_user, :id) || Map.get(current_user, "id") || username

    %{
      id: id,
      username: username,
      actor_type: :admin,
      scope: :global_dashboard
    }
  end

  defp send_pdf(conn, %Document{} = document) do
    conn
    |> put_resp_content_type(document.content_type)
    |> put_resp_header("content-disposition", "attachment; filename=\"#{document.filename}\"")
    |> put_private_pdf_headers()
    |> send_resp(200, document.binary)
  end

  defp send_failure(conn, status) do
    conn
    |> put_private_pdf_headers()
    |> send_resp(status, @failure)
  end

  defp put_private_pdf_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store, private")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
  end

  defp artifact_error_status(%ArtifactError{state: :not_found}), do: 404
  defp artifact_error_status(%ArtifactError{state: :ticket_revoked}), do: 410
  defp artifact_error_status(%ArtifactError{state: :ticket_not_ready}), do: 409
  defp artifact_error_status(%ArtifactError{state: :ticket_not_scannable}), do: 409
  defp artifact_error_status(%ArtifactError{state: :expired_link}), do: 409
  defp artifact_error_status(%ArtifactError{}), do: 409
end
