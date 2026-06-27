defmodule FastCheck.Messaging.WhatsApp.DeliveryPolicy do
  @moduledoc """
  Selects the allowed WhatsApp ticket delivery mode.
  """

  alias FastCheck.Messaging.WhatsApp.DeliveryWindow
  alias FastCheck.Messaging.WhatsApp.TemplateCatalog

  @type decision :: %{
          mode: :session_message | :template_message | :fallback_required,
          within_whatsapp_window: boolean(),
          template_key: atom() | nil,
          template: map() | nil,
          fallback_channel: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @spec select_ticket_delivery(map() | struct(), keyword()) :: decision()
  def select_ticket_delivery(conversation, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    fetch_template = Keyword.get(opts, :fetch_template, &TemplateCatalog.fetch/1)
    last_message_at = value(conversation, :last_message_at)
    within_window? = DeliveryWindow.inside?(last_message_at, now)

    if within_window? do
      %{
        mode: :session_message,
        within_whatsapp_window: true,
        template_key: nil,
        template: nil,
        fallback_channel: nil,
        failure_reason: nil
      }
    else
      template_key = ticket_ready_template_key(value(conversation, :preferred_language))

      case fetch_template.(template_key) do
        {:ok, template} ->
          %{
            mode: :template_message,
            within_whatsapp_window: false,
            template_key: template_key,
            template: template,
            fallback_channel: nil,
            failure_reason: nil
          }

        :error ->
          %{
            mode: :fallback_required,
            within_whatsapp_window: false,
            template_key: template_key,
            template: nil,
            fallback_channel: "manual_review",
            failure_reason: "whatsapp_template_unavailable"
          }
      end
    end
  end

  defp ticket_ready_template_key("en"), do: :ticket_ready_en
  defp ticket_ready_template_key(_language), do: :ticket_ready_af

  defp value(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value(struct, key), do: Map.get(struct, key)
end
