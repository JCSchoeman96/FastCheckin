defmodule FastCheck.TelemetrySecureTicketPathTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FastCheck.Observability.Redactor
  alias FastCheck.Telemetry

  @test_segment "opaque-telemetry-test-segment"

  setup do
    handler_id = {__MODULE__, :fastcheck_request, make_ref()}

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    {:ok, handler_id: handler_id}
  end

  test "slow request warning redacts secure-ticket request path", %{handler_id: _} do
    duration_native = System.convert_time_unit(6_000, :millisecond, :native)

    log =
      capture_log([level: :warning], fn ->
        Telemetry.handle_phoenix_endpoint(
          [:phoenix, :endpoint, :stop],
          %{duration: duration_native},
          %{
            request_path: "/t/#{@test_segment}/pdf",
            method: "GET",
            status: 200
          },
          %{}
        )
      end)

    refute log =~ @test_segment
    assert log =~ Redactor.redact_request_path("/t/#{@test_segment}/pdf")
  end

  test "emitted request event metadata never contains raw bearer token", %{handler_id: handler_id} do
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:fastcheck, :phoenix, :request],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:telemetry_metadata, metadata})
        end,
        nil
      )

    duration_native = System.convert_time_unit(100, :millisecond, :native)

    Telemetry.handle_phoenix_endpoint(
      [:phoenix, :endpoint, :stop],
      %{duration: duration_native},
      %{
        request_path: "/t/#{@test_segment}",
        method: "GET",
        status: 200
      },
      %{}
    )

    assert_receive {:telemetry_metadata, metadata}, 500
    refute inspect(metadata) =~ @test_segment
    assert metadata.route == Redactor.redact_request_path("/t/#{@test_segment}")
  end

  test "endpoint handler still emits telemetry when endpoint log policy would disable Phoenix logging" do
    parent = self()
    handler_id = {__MODULE__, :still_fires, make_ref()}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:fastcheck, :phoenix, :request],
        fn _event, _measurements, _metadata, _config ->
          send(parent, :telemetry_fired)
        end,
        nil
      )

    conn = Plug.Test.conn(:get, "/t/#{@test_segment}")

    assert FastCheckWeb.Observability.EndpointRequestLogPolicy.log_level(conn) == false

    duration_native = System.convert_time_unit(100, :millisecond, :native)

    Telemetry.handle_phoenix_endpoint(
      [:phoenix, :endpoint, :stop],
      %{duration: duration_native},
      %{conn: conn, options: %{}},
      %{}
    )

    assert_receive :telemetry_fired, 500
  end

  test "uses safe route template when present in metadata" do
    duration_native = System.convert_time_unit(100, :millisecond, :native)

    parent = self()
    handler_id = {__MODULE__, :route_template, make_ref()}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:fastcheck, :phoenix, :request],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:route, metadata.route})
        end,
        nil
      )

    Telemetry.handle_phoenix_endpoint(
      [:phoenix, :endpoint, :stop],
      %{duration: duration_native},
      %{
        route: "/t/:token",
        request_path: "/t/#{@test_segment}",
        method: "GET",
        status: 200
      },
      %{}
    )

    assert_receive {:route, "/t/:token"}, 500
  end
end
