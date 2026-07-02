defmodule FastCheck.Tickets.Resend.RequestTest do
  use ExUnit.Case, async: true

  alias FastCheck.Tickets.Resend.Request

  test "normalizes email, name, source, and now" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, normalized} =
             Request.normalize(%Request{
               name: "  Jamie---  Smith  ",
               email: "  JAMIE@example.COM ",
               source: %{"conversation_id" => "123", "phone_e164" => " +27821234567 "},
               correlation_id: " corr-1 ",
               idempotency_key: " idem-1 ",
               now: now
             })

    assert normalized.email == "jamie@example.com"
    assert normalized.name == "jamie smith"
    assert normalized.source.conversation_id == 123
    assert normalized.source.phone_e164 == "+27821234567"
    assert normalized.correlation_id == "corr-1"
    assert normalized.idempotency_key == "idem-1"
    assert normalized.now == now
  end

  test "rejects invalid or blank input generically" do
    assert {:error, :invalid_input} = Request.normalize(%{name: "Jamie", email: "bad"})
    assert {:error, :invalid_input} = Request.normalize(%{name: "", email: "j@example.com"})
    assert {:error, :invalid_input} = Request.normalize(%{name: "J", email: "j@example.com"})
    assert {:error, :invalid_input} = Request.normalize(%{name: "Jamie", email: ""})
  end
end
