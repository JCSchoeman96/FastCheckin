defmodule FastCheckWeb.Plugs.RawBodyReaderTest do
  use FastCheckWeb.ConnCase, async: true

  alias FastCheckWeb.Plugs.RawBodyReader

  test "POST /t/session body is readable without retaining raw_body" do
    conn =
      :post
      |> Plug.Test.conn("/t/session", "delivery_token=test")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")

    assert {:ok, body, conn} = RawBodyReader.read_body(conn, [])
    assert body =~ "delivery_token"
    refute conn.private[:raw_body]
  end

  test "paystack webhook retains raw_body for HMAC ingress" do
    payload = ~s({"event":"charge.success"})

    conn =
      :post
      |> Plug.Test.conn("/api/sales/paystack/webhook", payload)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert {:ok, body, conn} = RawBodyReader.read_body(conn, [])
    assert body == payload
    assert conn.private[:raw_body] == payload
  end
end
