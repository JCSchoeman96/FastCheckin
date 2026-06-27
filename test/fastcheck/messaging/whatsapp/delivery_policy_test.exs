defmodule FastCheck.Messaging.WhatsApp.DeliveryPolicyTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.DeliveryPolicy

  @now ~U[2026-06-27 10:00:00Z]

  test "selects session message delivery inside the 24 hour window" do
    conversation = conversation(last_message_at: ~U[2026-06-27 09:00:00Z])

    assert %{
             mode: :session_message,
             within_whatsapp_window: true,
             template_key: nil,
             template: nil
           } = DeliveryPolicy.select_ticket_delivery(conversation, now: @now)
  end

  test "selects Afrikaans ticket-ready template outside the 24 hour window" do
    conversation =
      conversation(last_message_at: ~U[2026-06-26 09:59:59Z], preferred_language: "af")

    assert %{
             mode: :template_message,
             within_whatsapp_window: false,
             template_key: :ticket_ready_af,
             template: %{name: "fastcheck_ticket_ready_af", language_code: "af"}
           } = DeliveryPolicy.select_ticket_delivery(conversation, now: @now)
  end

  test "selects English ticket-ready template outside the 24 hour window" do
    conversation = conversation(last_message_at: nil, preferred_language: "en")

    assert %{
             mode: :template_message,
             within_whatsapp_window: false,
             template_key: :ticket_ready_en,
             template: %{name: "fastcheck_ticket_ready_en", language_code: "en_US"}
           } = DeliveryPolicy.select_ticket_delivery(conversation, now: @now)
  end

  test "falls back to Afrikaans ticket-ready template for unknown languages" do
    conversation = conversation(last_message_at: nil, preferred_language: "zu")

    assert %{mode: :template_message, template_key: :ticket_ready_af} =
             DeliveryPolicy.select_ticket_delivery(conversation, now: @now)
  end

  test "requires fallback when the outside-window template is not configured" do
    conversation = conversation(last_message_at: nil, preferred_language: "en")

    fetch_template = fn :ticket_ready_en -> :error end

    assert %{
             mode: :fallback_required,
             within_whatsapp_window: false,
             fallback_channel: "manual_review",
             failure_reason: "whatsapp_template_unavailable",
             template_key: :ticket_ready_en,
             template: nil
           } =
             DeliveryPolicy.select_ticket_delivery(conversation,
               now: @now,
               fetch_template: fetch_template
             )
  end

  defp conversation(attrs) do
    %{
      last_message_at: Keyword.get(attrs, :last_message_at),
      preferred_language: Keyword.get(attrs, :preferred_language, "af")
    }
  end
end
