defimpl Inspect, for: FastCheck.Sales.TicketResendChallenge do
  import Inspect.Algebra

  def inspect(challenge, opts) do
    safe = %{
      public_id_present?: is_binary(challenge.public_id) and challenge.public_id != "",
      status: challenge.status,
      failed_attempt_count: challenge.failed_attempt_count,
      expires_at: challenge.expires_at,
      verified?: not is_nil(challenge.verified_at),
      consumed?: not is_nil(challenge.consumed_at),
      locked?: not is_nil(challenge.locked_until)
    }

    concat(["#FastCheck.Sales.TicketResendChallenge<", to_doc(safe, opts), ">"])
  end
end
