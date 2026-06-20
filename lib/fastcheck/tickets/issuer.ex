defmodule FastCheck.Tickets.Issuer do
  @moduledoc """
  Approved ticket issuance orchestration entrypoint for FastCheck Sales.

  Contract-only stub in VS-09A. Authoritative rules live in
  `docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md`.

  Production issuance is implemented in VS-09B/VS-09C. Only
  `FastCheck.Workers.IssueTicketsWorker` may call this module once implemented.
  """

  @doc """
  Issue tickets for a verified paid Sales order.

  See `docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md` for preconditions,
  return shapes, idempotency, and transaction model.
  """
  @spec issue_order(integer(), keyword()) :: no_return()
  def issue_order(_order_id, _opts \\ []) do
    raise "not implemented until VS-09B"
  end
end
