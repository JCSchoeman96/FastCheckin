defmodule FastCheck.Tickets.Resend.RateLimit do
  @moduledoc """
  DB-backed bounded rate checks for resend lookup and OTP challenge creation.

  Future Redis ZSET contract:

    * `ticket_resend:lookup:email:{request_email_hash}` - score unix timestamp, 15m TTL.
    * `ticket_resend:lookup:source:{source_hash}` - score unix timestamp, 15m TTL.
    * `ticket_resend:lookup:candidate:{candidate_hash}` - score unix timestamp, 24h TTL.
    * `ticket_resend:otp_failures:{public_id}` - score unix timestamp, 15m TTL.

  VS-24D-A intentionally uses indexed Postgres counts only and introduces no
  Redis dependency.
  """

  import Ecto.Query

  alias FastCheck.Repo

  @spec check_lookup(binary(), binary() | nil, DateTime.t()) :: :ok | {:error, atom()}
  def check_lookup(request_email_hash, source_hash, now) do
    case check_email(request_email_hash, now) do
      :ok -> check_source(source_hash, now)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec check_candidate(binary(), DateTime.t()) :: :ok | {:error, atom()}
  def check_candidate(candidate_hash, now) when is_binary(candidate_hash) do
    limit = config(:lookup_limit_per_candidate_day)
    window_start = DateTime.add(now, -86_400, :second)

    if count_since(:candidate_hash, candidate_hash, window_start) >= limit do
      {:error, :candidate_rate_limited}
    else
      :ok
    end
  end

  def check_candidate(_candidate_hash, _now), do: {:error, :candidate_rate_limited}

  defp check_email(request_email_hash, now) do
    limit = config(:lookup_limit_per_email_15m)
    window_start = DateTime.add(now, -900, :second)

    if count_since(:request_email_hash, request_email_hash, window_start) >= limit do
      {:error, :email_rate_limited}
    else
      :ok
    end
  end

  defp check_source(nil, _now), do: :ok

  defp check_source(source_hash, now) do
    limit = config(:lookup_limit_per_source_15m)
    window_start = DateTime.add(now, -900, :second)

    if count_since(:source_hash, source_hash, window_start) >= limit do
      {:error, :source_rate_limited}
    else
      :ok
    end
  end

  defp count_since(field, hash, window_start) do
    Repo.one!(
      from c in "sales_ticket_resend_challenges",
        where: field(c, ^field) == ^hash and c.inserted_at >= ^window_start,
        select: count(c.id)
    )
  end

  defp config(key) do
    :fastcheck
    |> Application.fetch_env!(:ticket_resend)
    |> Keyword.fetch!(key)
  end
end
