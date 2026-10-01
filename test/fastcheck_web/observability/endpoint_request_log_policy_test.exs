defmodule FastCheckWeb.Observability.EndpointRequestLogPolicyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias FastCheckWeb.Endpoint
  alias FastCheckWeb.Observability.EndpointRequestLogPolicy

  @test_segment "opaque-test-segment-not-a-real-token"

  test "endpoint Plug.Telemetry log MFA references EndpointRequestLogPolicy.log_level/1" do
    assert Endpoint.endpoint_request_log_mfa() ==
             {EndpointRequestLogPolicy, :log_level, []}
  end

  test "secure-ticket HTML path disables endpoint request logging" do
    conn = conn(:get, "/t/#{@test_segment}")
    assert EndpointRequestLogPolicy.log_level(conn) == false
  end

  test "secure-ticket PDF path disables endpoint request logging" do
    conn = conn(:get, "/t/#{@test_segment}/pdf")
    assert EndpointRequestLogPolicy.log_level(conn) == false
  end

  test "bare /t/ prefix disables endpoint request logging" do
    conn = conn(:get, "/t/")
    assert EndpointRequestLogPolicy.log_level(conn) == false
  end

  test "malformed /t/ paths disable endpoint request logging" do
    conn = conn(:get, "/t/foo/bar")
    assert EndpointRequestLogPolicy.log_level(conn) == false
  end

  test "dashboard path keeps normal endpoint logging level" do
    conn = conn(:get, "/dashboard")
    assert EndpointRequestLogPolicy.log_level(conn) == :info
  end

  test "mobile login path keeps normal endpoint logging level" do
    conn = conn(:get, "/api/v1/mobile/login")
    assert EndpointRequestLogPolicy.log_level(conn) == :info
  end
end
