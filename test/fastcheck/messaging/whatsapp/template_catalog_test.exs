defmodule FastCheck.Messaging.WhatsApp.TemplateCatalogTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.TemplateCatalog

  @expected_keys [
    :ticket_ready_af,
    :ticket_ready_en,
    :payment_pending_af,
    :payment_pending_en,
    :payment_link_af,
    :payment_link_en,
    :delivery_fallback_af,
    :delivery_fallback_en
  ]

  test "exposes exactly the initial VS-16 template keys" do
    assert TemplateCatalog.keys() == @expected_keys
  end

  test "fetch returns stable template names and language codes" do
    assert {:ok,
            %{
              key: :ticket_ready_af,
              name: "fastcheck_ticket_ready_af",
              language_code: "af"
            }} = TemplateCatalog.fetch(:ticket_ready_af)

    assert {:ok,
            %{
              key: :payment_link_en,
              name: "fastcheck_payment_link_en",
              language_code: "en_US"
            }} = TemplateCatalog.fetch(:payment_link_en)
  end

  test "unknown template keys are rejected" do
    assert :error = TemplateCatalog.fetch(:not_real)
    refute TemplateCatalog.exists?(:not_real)
  end
end
