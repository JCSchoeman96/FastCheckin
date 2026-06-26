defmodule FastCheck.Messaging.WhatsApp.MessageBuilder do
  @moduledoc """
  Builds Meta WhatsApp message payloads without performing HTTP calls.
  """

  alias FastCheck.Messaging.WhatsApp.Response
  alias FastCheck.Messaging.WhatsApp.TemplateCatalog

  @phone_regex ~r/^\+\d{8,15}$/
  @max_body_length 4_096
  @max_components 10

  @spec text_message(term(), term()) :: {:ok, map()} | {:error, Response.t()}
  def text_message(to_e164, body) do
    with {:ok, to} <- normalize_phone(to_e164),
         {:ok, body} <- normalize_body(body) do
      {:ok,
       %{
         "messaging_product" => "whatsapp",
         "to" => to,
         "type" => "text",
         "text" => %{
           "body" => body,
           "preview_url" => false
         }
       }}
    end
  end

  @spec template_message(term(), term(), term(), term()) :: {:ok, map()} | {:error, Response.t()}
  def template_message(to_e164, template_key, language_code, components) do
    with {:ok, to} <- normalize_phone(to_e164),
         {:ok, template} <- fetch_template(template_key),
         :ok <- validate_language(template, language_code),
         {:ok, components} <- validate_components(components) do
      {:ok,
       %{
         "messaging_product" => "whatsapp",
         "to" => to,
         "type" => "template",
         "template" => %{
           "name" => template.name,
           "language" => %{"code" => template.language_code},
           "components" => components
         }
       }}
    end
  end

  defp normalize_phone(phone) when is_binary(phone) do
    trimmed = String.trim(phone)

    if Regex.match?(@phone_regex, trimmed) do
      {:ok, String.trim_leading(trimmed, "+")}
    else
      {:error, validation_error("invalid_phone", "phone must be E.164")}
    end
  end

  defp normalize_phone(_), do: {:error, validation_error("invalid_phone", "phone must be E.164")}

  defp normalize_body(body) when is_binary(body) do
    trimmed = String.trim(body)

    if trimmed != "" and String.length(trimmed) <= @max_body_length do
      {:ok, trimmed}
    else
      {:error, validation_error("invalid_body", "message body is invalid")}
    end
  end

  defp normalize_body(_),
    do: {:error, validation_error("invalid_body", "message body is invalid")}

  defp fetch_template(template_key) do
    case TemplateCatalog.fetch(template_key) do
      {:ok, template} -> {:ok, template}
      :error -> {:error, validation_error("invalid_template", "template is not configured")}
    end
  end

  defp validate_language(%{language_code: language_code}, language_code), do: :ok

  defp validate_language(_template, _language_code) do
    {:error, validation_error("invalid_language", "template language does not match catalog")}
  end

  defp validate_components(components)
       when is_list(components) and length(components) <= @max_components do
    {:ok, components}
  end

  defp validate_components(_components) do
    {:error, validation_error("invalid_components", "template components are invalid")}
  end

  defp validation_error(code, message) do
    %Response{
      provider: :meta,
      status: :validation_error,
      provider_error_code: code,
      provider_error_message: message,
      retryable?: false
    }
  end
end
