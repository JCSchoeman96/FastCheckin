defmodule FastCheck.Messaging.WhatsApp.WebhookScope do
  @moduledoc """
  Enforces the configured WABA and phone-number scope for signed Meta events.

  Signature verification proves that Meta signed the bytes. It does not prove
  that the event belongs to this FastCheck installation, so scope filtering is
  deliberately separate and fail-closed.
  """

  alias FastCheck.Messaging.WhatsApp.Config

  @spec filter(map(), Config.t()) :: {:ok, map()} | {:ignore, :out_of_scope | :malformed_scope}
  def filter(payload, %Config{
        business_account_id: business_account_id,
        phone_number_id: phone_number_id
      })
      when is_map(payload) and is_binary(business_account_id) and is_binary(phone_number_id) do
    scoped_entries =
      payload
      |> Map.get("entry", [])
      |> List.wrap()
      |> Enum.flat_map(&scoped_entry(&1, business_account_id, phone_number_id))

    if scoped_entries == [] do
      {:ignore, :out_of_scope}
    else
      {:ok, Map.put(payload, "entry", scoped_entries)}
    end
  end

  def filter(_payload, _config), do: {:ignore, :malformed_scope}

  defp scoped_entry(
         %{"id" => entry_id, "changes" => changes} = entry,
         business_account_id,
         phone_number_id
       )
       when entry_id == business_account_id and is_list(changes) do
    scoped_changes = Enum.filter(changes, &scoped_change?(&1, phone_number_id))

    if scoped_changes == [], do: [], else: [%{entry | "changes" => scoped_changes}]
  end

  defp scoped_entry(_entry, _business_account_id, _phone_number_id), do: []

  defp scoped_change?(%{"value" => value}, phone_number_id) when is_map(value) do
    provider_activity? = Map.has_key?(value, "messages") or Map.has_key?(value, "statuses")

    provider_activity? and
      get_in(value, ["metadata", "phone_number_id"]) == phone_number_id
  end

  defp scoped_change?(_change, _phone_number_id), do: false
end
