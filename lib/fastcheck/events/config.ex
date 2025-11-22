defmodule FastCheck.Events.Config do
  @moduledoc """
  Handles fetching and persisting ticket configurations from Tickera.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias FastCheck.Repo
  alias FastCheck.Events.Event
  alias FastCheck.Events.CheckInConfiguration
  alias FastCheck.Attendees.Attendee
  alias FastCheck.TickeraClient
  alias FastCheck.Events.Sync
  alias FastCheck.Events.Cache

  @config_fields [
    :ticket_type,
    :ticket_name,
    :allowed_checkins,
    :allow_reentry,
    :allowed_entrances,
    :check_in_window_start,
    :check_in_window_end,
    :check_in_window_timezone,
    :check_in_window_days,
    :check_in_window_buffer_minutes,
    :time_basis,
    :time_basis_timezone,
    :daily_check_in_limit,
    :entrance_limit,
    :limit_per_order,
    :min_per_order,
    :max_per_order,
    :status,
    :message,
    :last_checked_in_date
  ]

  @config_replace_fields @config_fields ++ [:check_in_window, :updated_at]

  @doc """
  Fetches Tickera ticket configurations for an event and upserts them locally.

  Returns the count of configurations inserted/updated or an error tuple when
  credentials are missing or a remote fetch fails.
  """
  @spec fetch_and_store_ticket_configs(integer()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def fetch_and_store_ticket_configs(event_id) when is_integer(event_id) do
    Repo.transaction(fn ->
      case Repo.get(Event, event_id) do
        nil ->
          Repo.rollback("EVENT_NOT_FOUND")

        %Event{} = event ->
          case ensure_event_credentials(event) do
            {:ok, api_key} ->
              ticket_type_ids = load_ticket_type_ids(event.id)

              case persist_ticket_configs(event, ticket_type_ids, api_key) do
                {:ok, count} ->
                  case touch_last_config_sync(event.id) do
                    :ok ->
                      case Sync.touch_last_soft_sync(event.id) do
                        :ok -> count
                        {:error, reason} -> Repo.rollback(reason)
                      end

                    {:error, reason} ->
                      Repo.rollback(reason)
                  end

                {:error, reason} ->
                  Repo.rollback(reason)
              end

            {:error, :decryption_failed} ->
              Repo.rollback("CREDENTIAL_DECRYPTION_FAILED")

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, count} ->
        {:ok, count}

      {:error, reason}
      when reason in [
             "EVENT_NOT_FOUND",
             "MISSING_CREDENTIALS",
             "CONFIG_FETCH_FAILED",
             "CREDENTIAL_DECRYPTION_FAILED"
           ] ->
        {:error, reason}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _} ->
        {:error, "CONFIG_FETCH_FAILED"}
    end
  end

  def fetch_and_store_ticket_configs(_), do: {:error, "INVALID_EVENT"}

  # Private Helpers

  defp ensure_event_credentials(%Event{tickera_site_url: site_url} = event) do
    cond do
      not present?(site_url) ->
        {:error, "MISSING_CREDENTIALS"}

      true ->
        case Sync.get_tickera_api_key(event) do
          {:ok, api_key} -> {:ok, api_key}
          {:error, :decryption_failed} -> {:error, :decryption_failed}
        end
    end
  end

  defp ensure_event_credentials(_), do: {:error, "MISSING_CREDENTIALS"}

  defp persist_ticket_configs(%Event{id: event_id} = _event, [], _api_key) do
    Logger.info("No ticket types discovered for event #{event_id}; skipping config sync")
    {:ok, 0}
  end

  defp persist_ticket_configs(%Event{id: event_id} = event, ticket_type_ids, api_key)
       when is_list(ticket_type_ids) do
    ticket_type_ids
    |> Enum.reduce_while({:ok, 0}, fn ticket_type_id, {:ok, count} ->
      case TickeraClient.get_ticket_config(
             event.tickera_site_url,
             api_key,
             ticket_type_id
           ) do
        {:ok, config} ->
          case upsert_ticket_config(event_id, ticket_type_id, config) do
            {:ok, _record} ->
              Logger.info("Stored ticket config #{ticket_type_id} for event #{event_id}")
              {:cont, {:ok, count + 1}}

            {:error, %Changeset{} = changeset} ->
              Logger.error(
                "Failed to store ticket config #{ticket_type_id} for event #{event_id}: #{inspect(changeset.errors)}"
              )

              {:halt, {:error, "CONFIG_PERSISTENCE_FAILED"}}
          end

        {:error, code, message} ->
          Logger.error(
            "Tickera ticket config fetch failed for event #{event_id} ticket #{ticket_type_id}: #{code} – #{message}"
          )

          {:halt, {:error, "CONFIG_FETCH_FAILED"}}

        {:error, reason} ->
          Logger.error(
            "Tickera ticket config fetch failed for event #{event_id} ticket #{ticket_type_id}: #{inspect(reason)}"
          )

          {:halt, {:error, "CONFIG_FETCH_FAILED"}}
      end
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_ticket_config(event_id, ticket_type_id, config) do
    attrs = build_config_attrs(config, event_id, ticket_type_id)

    %CheckInConfiguration{}
    |> CheckInConfiguration.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, @config_replace_fields},
      conflict_target: [:event_id, :ticket_type_id],
      returning: true
    )
  end

  defp build_config_attrs(config, event_id, ticket_type_id) do
    config
    |> Map.take(@config_fields)
    |> Map.put(:event_id, event_id)
    |> Map.put(:ticket_type_id, ticket_type_id)
    |> normalize_config_dates()
    |> maybe_put_ticket_labels(config)
    |> maybe_put_check_in_window()
    |> Map.put(:updated_at, DateTime.utc_now())
    |> Map.update(:check_in_window_start, nil, &normalize_date_value/1)
    |> Map.update(:check_in_window_end, nil, &normalize_date_value/1)
    |> Map.update(:last_checked_in_date, nil, &normalize_date_value/1)
  end

  defp normalize_config_dates(attrs) do
    attrs
  end

  defp maybe_put_ticket_labels(attrs, config) do
    attrs
    |> Map.put(
      :ticket_type,
      pick_ticket_label(config, [:ticket_type, :ticket_title, :ticket_name])
    )
    |> Map.put(
      :ticket_name,
      pick_ticket_label(config, [:ticket_name, :ticket_title, :ticket_type])
    )
  end

  defp pick_ticket_label(config, keys) do
    Enum.find_value(keys, fn key -> presence(Map.get(config, key)) end)
  end

  defp maybe_put_check_in_window(attrs) do
    start_date = Map.get(attrs, :check_in_window_start)
    end_date = Map.get(attrs, :check_in_window_end)

    case build_date_range(start_date, end_date) do
      nil -> attrs
      %Postgrex.Range{} = range -> Map.put(attrs, :check_in_window, range)
    end
  end

  defp build_date_range(nil, nil), do: nil

  defp build_date_range(start_date, end_date) do
    %Postgrex.Range{
      lower: start_date,
      upper: end_date,
      lower_inclusive: true,
      upper_inclusive: false
    }
  end

  defp touch_last_config_sync(event_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(e in Event, where: e.id == ^event_id)
    |> Repo.update_all(set: [last_config_sync: now, updated_at: now])
    |> case do
      {1, _} ->
        Cache.invalidate_event_cache(event_id)
        Cache.invalidate_events_list_cache()
        :ok

      _ ->
        {:error, "EVENT_NOT_FOUND"}
    end
  end

  defp load_ticket_type_ids(event_id) do
    from(a in Attendee,
      where: a.event_id == ^event_id and not is_nil(a.ticket_type_id),
      select: a.ticket_type_id,
      distinct: true
    )
    |> Repo.all()
    |> Enum.reduce([], fn raw, acc ->
      case normalize_ticket_type_id(raw) do
        nil ->
          acc

        id ->
          if id in acc do
            acc
          else
            [id | acc]
          end
      end
    end)
  end

  defp normalize_ticket_type_id(value) when is_integer(value) and value > 0, do: value

  defp normalize_ticket_type_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        case Integer.parse(trimmed) do
          {number, _rest} when number > 0 -> number
          _ -> nil
        end
    end
  end

  defp normalize_ticket_type_id(%{} = value) do
    Map.get(value, :ticket_type_id)
    |> case do
      nil -> Map.get(value, "ticket_type_id")
      id -> id
    end
    |> case do
      nil -> nil
      id -> normalize_ticket_type_id(id)
    end
  end

  defp normalize_ticket_type_id(_), do: nil

  defp normalize_date_value(nil), do: nil
  defp normalize_date_value(%Date{} = date), do: date
  defp normalize_date_value(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp normalize_date_value(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)

  defp normalize_date_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        case Date.from_iso8601(trimmed) do
          {:ok, date} -> date
          _ -> nil
        end
    end
  end

  defp normalize_date_value(_value), do: nil

  defp present?(value) when is_binary(value), do: presence(value) != nil
  defp present?(_), do: false

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
