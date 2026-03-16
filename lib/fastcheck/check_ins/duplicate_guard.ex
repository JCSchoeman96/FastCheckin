defmodule FastCheck.CheckIns.DuplicateGuard do
  @moduledoc """
  Redis Set-backed admit dedupe guard.
  """

  import Ecto.Query, warn: false

  alias FastCheck.Redis
  alias FastCheck.Repo
  alias FastCheck.CheckIns.CheckInAttempt

  @spec admitted?(integer(), String.t()) :: boolean()
  def admitted?(event_id, normalized_code)
      when is_integer(event_id) and is_binary(normalized_code) do
    key = admitted_key(event_id)

    case Redis.command(["SISMEMBER", key, normalized_code]) do
      {:ok, 1} ->
        true

      {:ok, 0} ->
        Repo.exists?(
          from(attempt in CheckInAttempt,
            where:
              attempt.event_id == ^event_id and
                attempt.ticket_code == ^normalized_code and
                attempt.decision in ["accepted_confirmed", "accepted_offline_pending"]
          )
        )

      _ ->
        false
    end
  end

  def admitted?(_event_id, _normalized_code), do: false

  @spec mark_admitted(integer(), String.t()) :: :ok | {:error, term()}
  def mark_admitted(event_id, normalized_code)
      when is_integer(event_id) and is_binary(normalized_code) do
    case Redis.command(["SADD", admitted_key(event_id), normalized_code]) do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_admitted(_event_id, _normalized_code), do: {:error, :invalid_ticket_code}

  @spec admitted_key(integer()) :: String.t()
  def admitted_key(event_id), do: "admitted:#{event_id}"
end
