defmodule FastCheckWeb.Webhooks.PaystackController do
  @moduledoc """
  Paystack webhook HTTP ingress for FastCheck Sales.

  Accepts signed provider callbacks, delegates ingestion to
  `FastCheck.Sales.Payments.WebhookIngestion`, and returns quickly without
  performing transaction verification or ticket/payment mutation.
  """

  use FastCheckWeb, :controller

  require Logger

  alias FastCheck.Observability.Correlation
  alias FastCheck.Sales.Payments.WebhookIngestion

  def create(conn, _params) do
    raw_body = Map.get(conn.private, :raw_body, "")
    headers = req_headers_map(conn)
    correlation_id = conn |> get_req_header("x-request-id") |> List.first()

    case WebhookIngestion.ingest(raw_body, headers,
           correlation_id: correlation_id || Logger.metadata()[:request_id]
         ) do
      {:ok, _status, _event} ->
        send_resp(conn, 200, "")

      {:error, :invalid_signature} ->
        send_resp(conn, 401, "")

      {:error, :malformed_payload} ->
        send_resp(conn, 400, "")

      {:error, :webhook_disabled} ->
        send_resp(conn, 503, "")

      {:error, :transient, reason} ->
        Logger.error(
          "paystack_webhook_ingest_failed",
          Correlation.operational_metadata(%{reason: inspect(reason)})
        )

        send_resp(conn, 500, "")
    end
  end

  defp req_headers_map(conn) do
    conn.req_headers
    |> Enum.into(%{}, fn {key, value} -> {String.downcase(key), value} end)
  end
end
