defmodule FastCheck.Tickets.Resend.Eligibility do
  @moduledoc """
  Customer ticket resend eligibility and OTP challenge orchestration.

  This module does not send email, send WhatsApp messages, enqueue delivery
  workers, generate PDFs, rotate delivery tokens, or create delivery attempts.
  """

  import Ecto.Query

  alias FastCheck.Repo
  alias FastCheck.Tickets.Resend.Hash
  alias FastCheck.Tickets.Resend.Otp
  alias FastCheck.Tickets.Resend.RateLimit
  alias FastCheck.Tickets.Resend.Request
  alias FastCheck.Tickets.Resend.Result

  @type candidate :: %{
          sales_order_id: integer(),
          ticket_issue_id: integer(),
          attendee_id: integer(),
          event_id: integer()
        }

  @doc """
  Attempts to create an OTP challenge for exactly one eligible ticket candidate.

  Always returns a 3-tuple. Plaintext OTP is returned only when
  `return_otp?: true` is explicitly passed by an internal caller.
  """
  @spec request_otp_challenge(Request.t() | map(), keyword()) ::
          {:ok, Result.t(), nil | %{otp: binary()}}
  def request_otp_challenge(request, opts \\ []) do
    with {:ok, normalized} <- Request.normalize(request),
         request_email_hash <- Hash.email(normalized.email),
         request_name_hash <- Hash.name(normalized.name),
         source_hash <- Hash.source(normalized.source),
         :ok <- RateLimit.check_lookup(request_email_hash, source_hash, normalized.now),
         {:ok, candidate} <- find_candidate(normalized.email, normalized.name),
         candidate_hash <- Hash.candidate(candidate.sales_order_id, candidate.ticket_issue_id),
         :ok <- RateLimit.check_candidate(candidate_hash, normalized.now),
         {:ok, challenge, otp} <-
           Otp.issue(
             %{
               sales_order_id: candidate.sales_order_id,
               ticket_issue_id: candidate.ticket_issue_id,
               conversation_id: normalized.source[:conversation_id],
               request_email_hash: request_email_hash,
               request_name_hash: request_name_hash,
               source_hash: source_hash,
               candidate_hash: candidate_hash,
               metadata: safe_request_metadata(candidate, normalized)
             },
             normalized.now,
             return_otp?: Keyword.get(opts, :return_otp?, false)
           ) do
      result =
        Result.new(:accepted, :otp_challenge_created,
          challenge_public_id: challenge.public_id,
          metadata: safe_request_metadata(candidate, normalized)
        )

      {:ok, result, maybe_otp(otp)}
    else
      {:error, :email_rate_limited} ->
        {:ok, Result.new(:rate_limited, :rate_limited), nil}

      {:error, :source_rate_limited} ->
        {:ok, Result.new(:rate_limited, :rate_limited), nil}

      {:error, :candidate_rate_limited} ->
        {:ok, Result.new(:rate_limited, :rate_limited), nil}

      {:error, reason}
      when reason in [
             :invalid_input,
             :no_match,
             :ambiguous_match,
             :invalid_ticket,
             :otp_create_failed
           ] ->
        {:ok, Result.new(:generic_rejected, reason), nil}

      {:error, _reason} ->
        {:ok, Result.new(:generic_rejected, :invalid_ticket), nil}
    end
  end

  @spec find_candidate(binary(), binary()) :: {:ok, candidate()} | {:error, atom()}
  def find_candidate(normalized_email, normalized_name)
      when is_binary(normalized_email) and is_binary(normalized_name) do
    candidates =
      Repo.all(
        from o in "sales_orders",
          join: ti in "sales_ticket_issues",
          on: ti.sales_order_id == o.id,
          join: a in "attendees",
          on: a.id == ti.attendee_id,
          join: e in "events",
          on: e.id == o.event_id,
          where: fragment("lower(?)", o.buyer_email) == ^normalized_email,
          where: o.status == "ticket_issued",
          where: ti.status == "issued",
          where: ti.scanner_status == "valid",
          where: is_nil(ti.revoked_at),
          where: e.status != "archived",
          where: is_nil(a.revoked_at),
          where: is_nil(a.scan_eligibility) or a.scan_eligibility == "active",
          where:
            fragment(
              "regexp_replace(lower(coalesce(?, '')), '^wc-', '') IN ('completed', 'complete')",
              a.payment_status
            ),
          where:
            fragment(
              "btrim(regexp_replace(regexp_replace(lower(coalesce(?, '')), '[[:punct:]]+', ' ', 'g'), '\\s+', ' ', 'g'))",
              o.buyer_name
            ) == ^normalized_name or
              fragment(
                "btrim(regexp_replace(regexp_replace(lower(coalesce(?, '') || ' ' || coalesce(?, '')), '[[:punct:]]+', ' ', 'g'), '\\s+', ' ', 'g'))",
                a.first_name,
                a.last_name
              ) == ^normalized_name,
          order_by: [desc: o.inserted_at, desc: ti.id],
          limit: 2,
          select: %{
            sales_order_id: o.id,
            ticket_issue_id: ti.id,
            attendee_id: a.id,
            event_id: e.id
          }
      )

    case candidates do
      [candidate] -> {:ok, candidate}
      [] -> {:error, :no_match}
      [_first, _second | _rest] -> {:error, :ambiguous_match}
    end
  end

  def find_candidate(_email, _name), do: {:error, :invalid_input}

  defp maybe_otp(nil), do: nil
  defp maybe_otp(otp), do: %{otp: otp}

  defp safe_request_metadata(candidate, normalized) do
    %{
      source: "ticket_resend",
      sales_order_id: candidate.sales_order_id,
      ticket_issue_id: candidate.ticket_issue_id,
      event_id: candidate.event_id,
      conversation_id: normalized.source[:conversation_id],
      correlation_id: normalized.correlation_id,
      status: "pending",
      reason_code: "otp_challenge_created"
    }
  end
end
