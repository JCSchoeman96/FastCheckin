defmodule FastCheckWeb.MetricsPlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias FastCheckWeb.MetricsPlug

  setup do
    start_supervised!({
      TelemetryMetricsPrometheus.Core,
      metrics: FastCheckWeb.Telemetry.metrics(), start_async: false
    })

    :telemetry.execute(
      [:fastcheck, :operations, :oban, :jobs],
      %{value: 3},
      %{queue: "payments", state: "available"}
    )

    :ok
  end

  test "GET /metrics returns Prometheus text from the reporter" do
    conn =
      :get
      |> conn("/metrics")
      |> MetricsPlug.call([])

    assert conn.status == 200

    assert get_resp_header(conn, "content-type") == [
             "text/plain; version=0.0.4; charset=utf-8"
           ]

    assert conn.resp_body =~ "fastcheck_operations_oban_jobs"
    assert conn.resp_body =~ ~s(queue="payments")
    assert conn.resp_body =~ ~s(state="available")
  end

  test "POST /metrics does not return the scrape body" do
    conn =
      :post
      |> conn("/metrics")
      |> MetricsPlug.call([])

    assert conn.status == 404
    refute conn.resp_body =~ "fastcheck_operations_oban_jobs"
  end

  test "unknown paths return 404" do
    conn =
      :get
      |> conn("/health")
      |> MetricsPlug.call([])

    assert conn.status == 404
  end

  test "metrics are disabled in the default test config unless explicitly enabled" do
    refute Application.get_env(:fastcheck, :enable_metrics, false)

    refute System.get_env("ENABLE_METRICS") in ["1", "true", "yes", "TRUE", "YES"]
  end
end
