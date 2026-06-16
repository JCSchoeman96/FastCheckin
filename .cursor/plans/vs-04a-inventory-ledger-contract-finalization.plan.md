# VS-04A Implementation Plan

- Plan ID: VS-04A-inventory-ledger-contract-finalization
- Plan version: v1
- Status: Approved after reviewer feedback
- Scope: VS-04A Inventory Ledger Contract Finalization
- Authority: This file is the active implementation contract for VS-04A. The VS-04A feature pack is the upstream source. VS-00A-D decision docs and VS-01B, VS-01G, and VS-03 handoffs define the accepted baseline.
- Last updated: 2026-06-16

## Revision log

- v1 — initial VS-04A implementation plan based on the VS-04A feature pack,
  inventory docs, accepted decision docs, and merged Sales handoffs.

## Allowed file scope

- `.cursor/plans/vs-04a-inventory-ledger-contract-finalization.plan.md`
- `docs/fastcheck_sales/inventory/*.md`
- `docs/fastcheck_sales/slices/VS-04A_INVENTORY_LEDGER_CONTRACT_FINALIZATION.md`

## Forbidden file scope for VS-04A

- `lib/**`
- `test/**` (tests may run, but test files are unchanged)
- `priv/repo/migrations/**`
- `config/**`
- routes/controllers/liveviews/workers

## Execution checklist

1. Make `INVENTORY_MASTER_CONTRACT.md` the normative entry point and conflict
   resolver.
2. Finalize Redis key contract and ReservationLedger API signatures.
3. Finalize result envelopes and error families.
4. Finalize idempotency, lock behavior, and hold TTL/expiry rules.
5. Finalize degraded/fail-closed, restart/recovery, and reconciliation
   precedence.
6. Finalize cache/PubSub invalidation topic/event and payload constraints.
7. Finalize VS-04B and VS-04C RED/GREEN implementation expectations.
8. Produce the VS-04A slice summary document.

## Branch and commit plan

- Branch: `vs-04a-inventory-ledger-contract-finalization`
- Workflow:
  - `git switch main`
  - `git pull origin main`
  - `git switch -c vs-04a-inventory-ledger-contract-finalization`
- Commit style:
  - `docs(sales): finalize VS-04A inventory ledger contract`
  - `docs(plan): add VS-04A canonical implementation plan`

## Verification commands

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/sales/ticket_offer_boundary_test.exs`
- `mix test test/fastcheck/sales/ticket_offer_test.exs`
- `mix test test/fastcheck/sales/ticket_offer_policy_test.exs`
- `mix test test/fastcheck/sales/ticket_offer_cache_invalidation_test.exs`
- `mix test test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
- `mix test test/fastcheck/sales/`
- `mix test`
- `mix precommit`
