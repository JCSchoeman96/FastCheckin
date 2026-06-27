defmodule FastCheckWeb.TelemetrySalesMetricsTest do
  use ExUnit.Case, async: true

  alias FastCheckWeb.Telemetry

  @forbidden_tags [
    :phone,
    :email,
    :ticket_code,
    :provider_reference,
    :authorization_url,
    :token,
    :token_hash,
    :raw_payload,
    :message_body
  ]

  test "defines Sales telemetry metrics with low-cardinality tags only" do
    metrics = Telemetry.metrics()
    names = Enum.map(metrics, &Enum.join(&1.name, "."))

    for expected <- [
          "fastcheck.sales.checkout.reserved.count",
          "fastcheck.sales.checkout.expired.count",
          "fastcheck.sales.payment.webhook_received.count",
          "fastcheck.sales.payment.verified.count",
          "fastcheck.sales.payment.mismatch.count",
          "fastcheck.sales.ticket.issued.count",
          "fastcheck.sales.ticket.revoked.count",
          "fastcheck.sales.delivery.sent.count",
          "fastcheck.sales.delivery.failed.count",
          "fastcheck.sales.manual_review.opened.count"
        ] do
      assert expected in names
    end

    sales_metrics =
      Enum.filter(metrics, fn metric ->
        metric.name |> Enum.join(".") |> String.starts_with?("fastcheck.sales.")
      end)

    assert sales_metrics != []

    for metric <- sales_metrics do
      refute Enum.any?(metric.tags, &(&1 in @forbidden_tags)),
             "#{inspect(metric.name)} uses forbidden tags #{inspect(metric.tags)}"
    end
  end
end
