defmodule FastCheck.Tickets.CodeGenerator do
  @moduledoc """
  Generates high-entropy Sales ticket code candidates for later issuance.

  VS-08 returns candidates only. Database uniqueness and collision retry belong
  to VS-09 issuance; this module does not call `Repo`.
  """

  @ticket_code_pattern ~r/^[A-Za-z0-9\-\._]+$/
  @entropy_bytes 16

  @doc """
  Returns one random ticket code candidate.

  Format: `FC-` plus URL-safe Base64 (128 bits of entropy).
  """
  @spec generate() :: String.t()
  def generate do
    "FC-" <> Base.url_encode64(:crypto.strong_rand_bytes(@entropy_bytes), padding: false)
  end

  @doc """
  Returns whether `ticket_code` matches the scanner-safe alphabet used on check-in.
  """
  @spec scanner_safe?(String.t()) :: boolean()
  def scanner_safe?(ticket_code) when is_binary(ticket_code) do
    byte_size(ticket_code) in 3..100 and Regex.match?(@ticket_code_pattern, ticket_code)
  end

  def scanner_safe?(_), do: false
end
