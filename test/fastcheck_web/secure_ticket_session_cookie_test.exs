defmodule FastCheckWeb.SecureTicketSessionCookieTest do
  use ExUnit.Case, async: true

  alias FastCheckWeb.SecureTicketSessionCookie

  test "cookie contract name path and flags" do
    assert SecureTicketSessionCookie.cookie_name() == "_fastcheck_ticket_session"
    assert SecureTicketSessionCookie.cookie_path() == "/t"

    options = SecureTicketSessionCookie.cookie_options()
    assert Keyword.get(options, :http_only) == true
    assert Keyword.get(options, :same_site) == "Lax"
    assert Keyword.get(options, :path) == "/t"
    refute Keyword.has_key?(options, :max_age)
  end

  test "signed session id round-trips and payload stays session id only" do
    browser_session_id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    signed = SecureTicketSessionCookie.sign(browser_session_id)

    assert {:ok, returned} = SecureTicketSessionCookie.verify(signed)
    assert returned == browser_session_id

    refute signed == browser_session_id
    refute String.contains?(signed, "ticket:")
    refute String.contains?(signed, "delivery")
    refute String.contains?(signed, "v1:")
  end

  test "tampered cookie is rejected" do
    browser_session_id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    signed = SecureTicketSessionCookie.sign(browser_session_id)

    tampered =
      case String.split_at(signed, div(byte_size(signed), 2)) do
        {left, right} -> left <> "X" <> right
      end

    assert {:error, :invalid} = SecureTicketSessionCookie.verify(tampered)
    assert {:error, :invalid} = SecureTicketSessionCookie.verify(signed <> "extra")
  end
end
