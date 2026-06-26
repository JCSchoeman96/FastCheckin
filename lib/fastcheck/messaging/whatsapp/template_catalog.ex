defmodule FastCheck.Messaging.WhatsApp.TemplateCatalog do
  @moduledoc """
  Stable local catalog for approved Meta WhatsApp template names and languages.
  """

  @templates [
    %{key: :ticket_ready_af, name: "fastcheck_ticket_ready_af", language_code: "af"},
    %{key: :ticket_ready_en, name: "fastcheck_ticket_ready_en", language_code: "en_US"},
    %{key: :payment_pending_af, name: "fastcheck_payment_pending_af", language_code: "af"},
    %{key: :payment_pending_en, name: "fastcheck_payment_pending_en", language_code: "en_US"},
    %{key: :payment_link_af, name: "fastcheck_payment_link_af", language_code: "af"},
    %{key: :payment_link_en, name: "fastcheck_payment_link_en", language_code: "en_US"},
    %{key: :delivery_fallback_af, name: "fastcheck_delivery_fallback_af", language_code: "af"},
    %{key: :delivery_fallback_en, name: "fastcheck_delivery_fallback_en", language_code: "en_US"}
  ]

  @spec keys() :: [atom()]
  def keys do
    Enum.map(@templates, & &1.key)
  end

  @spec fetch(atom()) :: {:ok, map()} | :error
  def fetch(key) when is_atom(key) do
    case Enum.find(@templates, &(&1.key == key)) do
      nil -> :error
      template -> {:ok, template}
    end
  end

  def fetch(_), do: :error

  @spec exists?(term()) :: boolean()
  def exists?(key), do: match?({:ok, _}, fetch(key))
end
