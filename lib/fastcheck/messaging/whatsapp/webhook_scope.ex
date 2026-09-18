defmodule FastCheck.Messaging.WhatsApp.WebhookScope do
  @moduledoc """
  Pure filtering for signed Meta WhatsApp webhook payloads.

  Signature verification happens separately in `WebhookVerifier`. This module
  only keeps message and status changes belonging to the configured WABA and
  phone number.
  """

  alias FastCheck.Messaging.WhatsApp.Config

  @type reason :: :out_of_scope | :malformed_scope
  @type result :: {:ok, map()} | {:ignore, reason()}

  @spec filter(map(), Config.t()) :: result()
  def filter(payload, %Config{} = config) when is_map(payload) do
    with {:ok, entries} <- entries(payload),
         {scoped_entries, malformed?} <- scope_entries(entries, config) do
      cond do
        scoped_entries != [] -> {:ok, Map.put(payload, "entry", scoped_entries)}
        malformed? -> {:ignore, :malformed_scope}
        true -> {:ignore, :out_of_scope}
      end
    else
      :error -> {:ignore, :malformed_scope}
    end
  end

  def filter(_payload, _config), do: {:ignore, :malformed_scope}

  defp entries(payload) do
    case Map.get(payload, "entry") do
      entries when is_list(entries) -> {:ok, entries}
      _ -> :error
    end
  end

  defp scope_entries(entries, config) do
    Enum.reduce(entries, {[], false}, fn entry, {scoped_entries, malformed?} ->
      case scope_entry(entry, config) do
        {:ok, scoped_entry} when is_map(scoped_entry) ->
          {[scoped_entry | scoped_entries], malformed?}

        :out_of_scope ->
          {scoped_entries, malformed?}

        :malformed ->
          {scoped_entries, true}

        {:ok, nil} ->
          {scoped_entries, malformed?}
      end
    end)
    |> then(fn {scoped_entries, malformed?} -> {Enum.reverse(scoped_entries), malformed?} end)
  end

  defp scope_entry(%{"id" => entry_id, "changes" => changes} = entry, config)
       when is_binary(entry_id) and is_list(changes) do
    if entry_id == config.business_account_id do
      case scope_changes(changes, config) do
        {:ok, []} -> {:ok, nil}
        {:ok, scoped_changes} -> {:ok, Map.put(entry, "changes", scoped_changes)}
        result -> result
      end
    else
      :out_of_scope
    end
  end

  defp scope_entry(%{"id" => _entry_id}, _config), do: :malformed
  defp scope_entry(_entry, _config), do: :malformed

  defp scope_changes(changes, config) do
    {matching_changes, malformed?} =
      Enum.reduce(changes, {[], false}, fn change, {matching, malformed?} ->
        case scope_change(change, config) do
          {:ok, scoped_change} -> {[scoped_change | matching], malformed?}
          :out_of_scope -> {matching, malformed?}
          :malformed -> {matching, true}
          :unsupported -> {matching, malformed?}
        end
      end)

    case Enum.reverse(matching_changes) do
      [] -> if malformed?, do: :malformed, else: {:ok, []}
      scoped_changes -> {:ok, scoped_changes}
    end
  end

  defp scope_change(%{"value" => value} = change, config) when is_map(value) do
    case Map.get(value, "metadata") do
      %{"phone_number_id" => phone_number_id} when is_binary(phone_number_id) ->
        cond do
          phone_number_id != config.phone_number_id -> :out_of_scope
          relevant_activity?(value) -> {:ok, change}
          true -> :unsupported
        end

      _ ->
        :malformed
    end
  end

  defp scope_change(_change, _config), do: :malformed

  defp relevant_activity?(value) do
    present_list?(Map.get(value, "messages")) or present_list?(Map.get(value, "statuses"))
  end

  defp present_list?(value), do: is_list(value) and value != []
end
