defmodule FastCheck.Tickets.Resend.Otp do
  @moduledoc """
  OTP challenge issue and verification contract for ticket resend.

  Plaintext OTPs exist only as in-memory return values for internal callers that
  explicitly opt in. Stored values are hashes only.
  """

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Repo
  alias FastCheck.Sales.TicketResendChallenge
  alias FastCheck.Tickets.Resend.Hash

  require Ash.Query

  @type issue_attrs :: %{
          required(:sales_order_id) => integer(),
          required(:ticket_issue_id) => integer(),
          optional(:conversation_id) => integer() | nil,
          required(:request_email_hash) => binary(),
          optional(:request_name_hash) => binary() | nil,
          optional(:source_hash) => binary() | nil,
          required(:candidate_hash) => binary(),
          optional(:metadata) => map()
        }

  @spec issue(issue_attrs(), DateTime.t(), keyword()) ::
          {:ok, TicketResendChallenge.t(), binary() | nil} | {:error, term()}
  def issue(attrs, now, opts \\ []) when is_map(attrs) do
    otp = generate_code()
    public_id = public_id()
    expires_at = DateTime.add(now, config(:otp_ttl_seconds), :second)

    create_attrs =
      attrs
      |> Map.take([
        :sales_order_id,
        :ticket_issue_id,
        :conversation_id,
        :request_email_hash,
        :request_name_hash,
        :source_hash,
        :candidate_hash,
        :metadata
      ])
      |> Map.merge(%{
        public_id: public_id,
        otp_hash: Hash.otp(public_id, otp),
        expires_at: expires_at
      })

    case TicketResendChallenge
         |> Changeset.for_create(:create_pending, create_attrs, actor: system_actor())
         |> Ash.create() do
      {:ok, challenge} ->
        returned_otp = if Keyword.get(opts, :return_otp?, false), do: otp, else: nil
        {:ok, challenge, returned_otp}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec issue_lookup_attempt(map(), DateTime.t()) ::
          {:ok, TicketResendChallenge.t()} | {:error, term()}
  def issue_lookup_attempt(attrs, now) when is_map(attrs) do
    expires_at = DateTime.add(now, config(:otp_ttl_seconds), :second)

    create_attrs =
      attrs
      |> Map.take([
        :sales_order_id,
        :ticket_issue_id,
        :conversation_id,
        :request_email_hash,
        :request_name_hash,
        :source_hash,
        :candidate_hash,
        :metadata
      ])
      |> Map.merge(%{
        public_id: public_id(),
        expires_at: expires_at
      })

    case TicketResendChallenge
         |> Changeset.for_create(:create_pending, create_attrs, actor: system_actor())
         |> Ash.create() do
      {:ok, challenge} -> {:ok, challenge}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec verify(binary(), binary(), DateTime.t()) ::
          {:ok, TicketResendChallenge.t()}
          | {:error, :invalid_or_expired | :locked | :already_verified}
  def verify(public_id, otp, now) when is_binary(public_id) and is_binary(otp) do
    Repo.transaction(fn ->
      case fetch_challenge(public_id) do
        nil ->
          {:error, :invalid_or_expired}

        %{status: status} when status in ["verified", "consumed"] ->
          {:error, :already_verified}

        %{status: status} when status in ["blocked", "manual_review"] ->
          {:error, :locked}

        %{status: "expired"} ->
          {:error, :invalid_or_expired}

        challenge ->
          verify_pending(challenge, otp, now)
      end
    end)
    |> case do
      {:ok, {:ok, challenge}} -> {:ok, challenge}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_public_id, _otp, _now), do: {:error, :invalid_or_expired}

  @spec generate_code(pos_integer() | nil) :: binary()
  def generate_code(length \\ nil) do
    length = length || config(:otp_length)

    length
    |> strong_digits([])
    |> IO.iodata_to_binary()
  end

  defp strong_digits(0, digits), do: Enum.reverse(digits)

  defp strong_digits(remaining, digits) do
    digit =
      1
      |> :crypto.strong_rand_bytes()
      |> :binary.first()
      |> rem(10)
      |> Integer.to_string()

    strong_digits(remaining - 1, [digit | digits])
  end

  defp fetch_challenge(public_id) do
    Repo.one(
      from c in "sales_ticket_resend_challenges",
        where: c.public_id == ^public_id,
        lock: "FOR UPDATE",
        select:
          map(c, [
            :id,
            :public_id,
            :status,
            :otp_hash,
            :failed_attempt_count,
            :expires_at,
            :locked_until
          ])
    )
    |> normalize_challenge_times()
  end

  defp verify_pending(challenge, otp, now) do
    cond do
      DateTime.compare(challenge.expires_at, now) != :gt ->
        mark_expired!(challenge.id, now)
        {:error, :invalid_or_expired}

      locked?(challenge, now) ->
        {:error, :locked}

      secure_match?(challenge.otp_hash, Hash.otp(challenge.public_id, otp)) ->
        {:ok, mark_verified!(challenge.id, now)}

      true ->
        record_failed_attempt!(challenge, now)
        {:error, :invalid_or_expired}
    end
  end

  defp mark_verified!(id, now) do
    {1, _} =
      Repo.update_all(
        from(c in "sales_ticket_resend_challenges",
          where: c.id == ^id and c.status == "pending"
        ),
        set: [status: "verified", verified_at: now, updated_at: now]
      )

    get_challenge!(id)
  end

  defp mark_expired!(id, now) do
    Repo.update_all(
      from(c in "sales_ticket_resend_challenges",
        where: c.id == ^id and c.status in ["pending", "verified"]
      ),
      set: [status: "expired", updated_at: now]
    )
  end

  defp record_failed_attempt!(challenge, now) do
    failed_attempt_count = challenge.failed_attempt_count + 1

    if failed_attempt_count >= config(:max_failed_attempts) do
      locked_until = DateTime.add(now, config(:lock_seconds), :second)

      Repo.update_all(
        from(c in "sales_ticket_resend_challenges",
          where: c.id == ^challenge.id and c.status == "pending"
        ),
        set: [
          status: "blocked",
          failed_attempt_count: failed_attempt_count,
          locked_until: locked_until,
          failure_reason: "too_many_otp_failures",
          updated_at: now
        ]
      )
    else
      Repo.update_all(
        from(c in "sales_ticket_resend_challenges",
          where: c.id == ^challenge.id and c.status == "pending"
        ),
        set: [
          failed_attempt_count: failed_attempt_count,
          failure_reason: "otp_mismatch",
          updated_at: now
        ]
      )
    end
  end

  defp get_challenge!(id) do
    TicketResendChallenge
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(actor: system_actor())
  end

  defp locked?(challenge, now) do
    not is_nil(challenge.locked_until) and DateTime.compare(challenge.locked_until, now) == :gt
  end

  defp normalize_challenge_times(nil), do: nil

  defp normalize_challenge_times(challenge) do
    challenge
    |> Map.update!(:expires_at, &to_utc_datetime/1)
    |> Map.update!(:locked_until, &to_utc_datetime/1)
  end

  defp to_utc_datetime(nil), do: nil
  defp to_utc_datetime(%DateTime{} = datetime), do: datetime

  defp to_utc_datetime(%NaiveDateTime{} = naive) do
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp public_id do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp config(key) do
    :fastcheck
    |> Application.fetch_env!(:ticket_resend)
    |> Keyword.fetch!(key)
  end

  defp system_actor, do: %{actor_type: :system, id: "ticket_resend"}

  defp secure_match?(expected, actual) when is_binary(expected) and is_binary(actual) do
    byte_size(expected) == byte_size(actual) and Plug.Crypto.secure_compare(expected, actual)
  end

  defp secure_match?(_expected, _actual), do: false
end
