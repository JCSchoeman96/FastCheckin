defmodule FastCheck.Messaging.WhatsApp.MessageBuilderTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.MessageBuilder

  test "text_message accepts E.164 input and strips plus for Meta payload" do
    assert {:ok, payload} = MessageBuilder.text_message("+27821234567", "Hallo")

    assert payload == %{
             "messaging_product" => "whatsapp",
             "to" => "27821234567",
             "type" => "text",
             "text" => %{
               "body" => "Hallo",
               "preview_url" => false
             }
           }
  end

  test "template_message builds exact template payload with language and components" do
    components = [
      %{
        "type" => "body",
        "parameters" => [%{"type" => "text", "text" => "ORD-123"}]
      }
    ]

    assert {:ok, payload} =
             MessageBuilder.template_message(
               "+27821234567",
               :payment_link_af,
               "af",
               components
             )

    assert payload == %{
             "messaging_product" => "whatsapp",
             "to" => "27821234567",
             "type" => "template",
             "template" => %{
               "name" => "fastcheck_payment_link_af",
               "language" => %{"code" => "af"},
               "components" => components
             }
           }
  end

  test "invalid text input fails before HTTP" do
    assert {:error, error} = MessageBuilder.text_message("27821234567", "Hallo")
    assert error.status == :validation_error
    assert error.provider_error_code == "invalid_phone"

    assert {:error, error} = MessageBuilder.text_message("+27821234567", "   ")
    assert error.status == :validation_error
    assert error.provider_error_code == "invalid_body"

    assert {:error, error} =
             MessageBuilder.text_message("+27821234567", String.duplicate("a", 4097))

    assert error.status == :validation_error
    assert error.provider_error_code == "invalid_body"
  end

  test "invalid template input fails before HTTP" do
    assert {:error, error} =
             MessageBuilder.template_message("+27821234567", :not_real, "af", [])

    assert error.status == :validation_error
    assert error.provider_error_code == "invalid_template"

    assert {:error, error} =
             MessageBuilder.template_message("+27821234567", :payment_link_af, "en_US", [])

    assert error.status == :validation_error
    assert error.provider_error_code == "invalid_language"

    assert {:error, error} =
             MessageBuilder.template_message(
               "+27821234567",
               :payment_link_af,
               "af",
               List.duplicate(%{"type" => "body"}, 11)
             )

    assert error.status == :validation_error
    assert error.provider_error_code == "invalid_components"
  end
end
