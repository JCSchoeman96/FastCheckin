defmodule FastCheck.Observability.CorrelationTest do
  use ExUnit.Case, async: true

  alias FastCheck.Observability.Correlation

  test "ensure_correlation_id/1 preserves existing correlation_id" do
    assert Correlation.ensure_correlation_id(%{correlation_id: "corr-123"}) == "corr-123"
  end

  test "ensure_correlation_id/1 falls back to request_id" do
    assert Correlation.ensure_correlation_id(%{request_id: "req-456"}) == "req-456"
  end

  test "ensure_correlation_id/1 generates a new id when none exists" do
    id = Correlation.ensure_correlation_id(%{})

    assert is_binary(id)
    assert byte_size(id) > 0
  end

  test "ensure_correlation_id/1 never uses buyer phone or email" do
    id =
      Correlation.ensure_correlation_id(%{
        buyer_phone: "+27123456789",
        buyer_email: "buyer@example.com"
      })

    refute id == "+27123456789"
    refute id == "buyer@example.com"
  end

  test "merge_metadata/2 preserves an existing correlation_id from the left map" do
    merged =
      Correlation.merge_metadata(%{correlation_id: "left-id"}, %{
        correlation_id: "right-id",
        order_id: "order-1"
      })

    assert merged.correlation_id == "left-id"
    assert merged.order_id == "order-1"
  end

  test "for_oban_args/1 extracts only bounded operational keys" do
    args = %{
      "correlation_id" => "corr-1",
      "offer_id" => 99,
      "delivery_token" => "secret",
      "mode" => "dry_run"
    }

    assert Correlation.for_oban_args(args) == %{correlation_id: "corr-1"}
  end

  test "operational_metadata/1 can include idempotency_key explicitly" do
    metadata =
      Correlation.operational_metadata(%{
        order_id: "order-1",
        idempotency_key: "idem-1",
        buyer_phone: "+27111"
      })

    assert Keyword.keyword?(metadata)
    assert Keyword.get(metadata, :order_id) == "order-1"
    assert Keyword.get(metadata, :idempotency_key) == "idem-1"
    refute Keyword.has_key?(metadata, :buyer_phone)
  end
end
