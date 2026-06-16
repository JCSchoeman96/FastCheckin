defmodule FastCheckWeb.SentryFilterTest do
  use ExUnit.Case, async: true

  alias FastCheck.Observability.Redactor
  alias FastCheckWeb.SentryFilter

  test "recursively filters request data, headers, query params, and extra" do
    event = %{
      request: %{
        data: %{
          buyer_email: "secret@example.com",
          nested: %{raw_payload: %{"token" => "secret"}}
        },
        headers: %{
          "authorization" => "Bearer secret",
          "x-paystack-signature" => "sig-secret",
          "content-type" => "application/json"
        },
        query_string: "access_code=secret&order_id=order-1",
        query: %{"access_code" => "secret", "order_id" => "order-1"},
        url: "https://example.com/tickets/secret-token?access_code=secret"
      },
      extra: %{
        provider_payload: %{
          message_body: "WhatsApp secret",
          nested: %{delivery_token: "token-secret"}
        }
      }
    }

    filtered = SentryFilter.filter_event(event)

    assert filtered.request.data[:buyer_email] == "j***@example.com"
    assert get_in(filtered.request.data, [:nested, :raw_payload]) == Redactor.filtered()
    assert filtered.request.headers["authorization"] == Redactor.filtered()
    assert filtered.request.headers["x-paystack-signature"] == Redactor.filtered()
    assert filtered.request.headers["content-type"] == "application/json"
    refute filtered.request.query_string =~ "access_code"
    assert filtered.request.query["access_code"] == Redactor.filtered()
    assert filtered.request.query["order_id"] == "order-1"
    assert filtered.request.url == Redactor.filtered()

    assert get_in(filtered.extra, [:provider_payload, :message_body]) ==
             Redactor.filtered_message()

    assert get_in(filtered.extra, [:provider_payload, :nested, :delivery_token]) ==
             Redactor.filtered()
  end

  test "preserves safe ids in request and extra data" do
    event = %{
      request: %{
        data: %{
          order_id: "order-1",
          payment_attempt_id: "pay-1",
          ticket_issue_id: "ticket-1",
          delivery_token: "secret"
        },
        headers: %{},
        query: %{}
      },
      extra: %{
        order_id: "order-1",
        payment_attempt_id: "pay-1",
        ticket_issue_id: "ticket-1"
      }
    }

    filtered = SentryFilter.filter_event(event)

    assert filtered.request.data.order_id == "order-1"
    assert filtered.request.data.payment_attempt_id == "pay-1"
    assert filtered.request.data.ticket_issue_id == "ticket-1"
    assert filtered.request.data.delivery_token == Redactor.filtered()
    assert filtered.extra.order_id == "order-1"
    assert filtered.extra.payment_attempt_id == "pay-1"
    assert filtered.extra.ticket_issue_id == "ticket-1"
  end

  test "does not crash on non-map request fields" do
    event = %{
      request: %{
        data: "plain-body",
        headers: "invalid",
        query_string: 123,
        query: ["not", "a", "map"],
        url: :not_a_binary
      },
      extra: "plain-extra"
    }

    assert %{} = SentryFilter.filter_event(event)
  end
end
