# P0-D revocation completeness and purchase ceiling implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Revoke every issued ticket on an Order, block refund/cancel transitions while any remain, and cap every new customer Order at 50 tickets.

**Architecture:** `FastCheck.Tickets.Revocation` will hold the existing Order advisory lock used by `Issuer`, page through issued TicketIssues by ascending ID in batches of 50, aggregate scanner invalidations once, and verify the final database count inside one transaction. Admin refund/cancel will take the same Order lock and check the count again before changing state. A central `FastCheck.Sales.PurchaseLimits` policy will enforce the customer ceiling in Checkout, TicketOffer actions, OfferManagement, Event WhatsApp configuration, and the WhatsApp conversation.

**Tech Stack:** Elixir, Phoenix, Ash, Ecto, PostgreSQL, ExUnit, LiveView, Redis inventory reservation.

---

## Files and responsibilities

- Modify `lib/fastcheck/tickets/revocation.ex` for bounded keyset pages, shared advisory locking, final remaining-issued count, and one post-commit cache invalidation.
- Modify `lib/fastcheck/sales/admin_revocations.ex` and `lib/fastcheck/sales/admin_refunds.ex` so incomplete revocation is a safe failure and terminal Order transitions recheck the database under the same Order lock.
- Create `lib/fastcheck/sales/purchase_limits.ex` for the single platform ceiling and quantity validation.
- Modify `lib/fastcheck/sales/checkout.ex`, `lib/fastcheck/sales/offer_management.ex`, and `lib/fastcheck/sales/ticket_offer.ex` to reject quantity or configuration above 50 before side effects or persistence.
- Modify `lib/fastcheck/events.ex`, `lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex`, and `lib/fastcheck_web/live/sales/whatsapp_offer_live.ex` to enforce and present the effective WhatsApp maximum.
- Extend `test/fastcheck/tickets/revocation_test.exs`, `test/fastcheck/sales/admin_revocations_test.exs`, `test/fastcheck/sales/admin_refunds_test.exs`, `test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs`, Checkout/OfferManagement/TicketOffer/Event/WhatsApp tests, and `test/fastcheck_web/sales/whatsapp_offer_live_test.exs`.
- Add `docs/fastcheck_sales/feature_packs/0053_P0-D_revocation-completeness-and-purchase-ceiling/` and update `docs/fastcheck_sales/state_machines/ORDER_STATE_MACHINE.md` and `TICKET_ISSUE_STATE_MACHINE.md`.
- Add no migration. Historical orders above 50 remain readable and revocable.

## Task 1: Prove and implement complete order revocation

- [ ] Add red tests for 50-, 51-, and 60-ticket fixtures. Assert every issue is revoked, every linked attendee is not scannable, the result reports `remaining_issued_count: 0`, and one event sync bump/invalidation batch is recorded.
- [ ] Add a 60-ticket page-two failure test that makes issue 55 unsafe to revoke. Assert the result is incomplete, issue 55 stays issued and scanner-valid, and the other tickets follow savepoint semantics. Repair the fixture and retry; assert only the remaining issue is processed and no prior invalidation repeats.
- [ ] Add a 60-ticket aggregator-failure test. Assert all ticket, attendee, invalidation, and event-version writes roll back; retry with the healthy aggregator and assert completion.
- [ ] Add a synchronized Issuer/revocation concurrency regression. Both operations must use `SELECT pg_advisory_xact_lock(order_id)` and may not leave a scanner-valid ticket after revocation completes.
- [ ] Replace the single Ash `LIMIT 50` read with `Repo.all/1` pages filtered by `sales_order_id`, `status == "issued"`, and `id > last_seen_id`, sorted by ID and limited to 50. Use a prepended accumulator so each page remains bounded and result assembly is linear.
- [ ] Start one outer transaction, take the Order advisory lock before reloading the Order, process each ticket in a nested savepoint, and continue through every page. Count issued rows in PostgreSQL before reporting success. Add `:order_revocation_incomplete` to failures if the count is nonzero without an existing ticket failure.
- [ ] Keep the mobile sync aggregate in the outer transaction and collect compact attendee IDs/codes for one post-commit cache invalidation. Do not retain page TicketIssue structs after processing.
- [ ] Run `mix test test/fastcheck/tickets/revocation_test.exs` and verify the new regressions fail before the implementation and pass after it.

## Task 2: Guard admin revocation, refund, and cancellation

- [ ] Add tests proving AdminRevocations reports an explicit safe failure when `remaining_issued_count` is nonzero and emits no completion telemetry.
- [ ] Add synthetic 60-ticket refund and cancellation tests. Confirm all 60 issues and attendees are revoked before the final Order status is written. Check scanner rejection for issues 1 and 60.
- [ ] Extend the page-two failure test through both admin marker workflows. Assert incomplete refund/cancel returns failure and moves the Order to manual review where the current policy does so.
- [ ] Add a finalization helper in AdminRefunds that starts a transaction, acquires the shared Order advisory lock, reloads the Order, counts issued TicketIssues, rolls back with a safe incomplete error when the count is above zero, and performs the existing Ash state transition while still holding the lock.
- [ ] Preserve reason, admin password, bulk confirmation, event authorization, StateTransition audit, and existing idempotency behavior.
- [ ] Run `mix test test/fastcheck/sales/admin_revocations_test.exs test/fastcheck/sales/admin_refunds_test.exs test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs`.

## Task 3: Add the central platform quantity policy

- [ ] Add unit tests for `PurchaseLimits.max_tickets_per_order/0` and its boundary validation.
- [ ] Add Checkout tests where 50 is accepted if all lower caps and inventory permit, and 51 returns `:platform_max_per_order_exceeded` before database, Redis, or Oban side effects. Count Orders, OrderLines, CheckoutSessions, PaymentAttempts, reservations, and jobs.
- [ ] Add `FastCheck.Sales.PurchaseLimits` with one canonical maximum of 50 and a quantity validator.
- [ ] Call that validator immediately after Checkout request shape validation and before conversation lookup, offer loading, reservation, or persistence. Keep the rule independent of source channel, offer/event caps, inventory, and actor.
- [ ] Run the Checkout tests and `mix test test/fastcheck/sales/checkout_event_quantity_limit_test.exs`.

## Task 4: Cap Offer configuration through every supported path

- [ ] Add OfferManagement create and update tests at 50 and 51, asserting a stable `:platform_max_per_order_exceeded` error at 51 and no Redis mutation.
- [ ] Add direct Ash TicketOffer create and update tests that attempt 51 and assert no offer persists.
- [ ] Use PurchaseLimits in OfferManagement parsing and return its canonical domain error before inventory initialization or persistence.
- [ ] Add TicketOffer create/update Ash validations that reject `max_per_order > PurchaseLimits.max_tickets_per_order/0`. Leave `configured_quantity_available` and `initial_quantity` unrestricted by the platform ceiling.
- [ ] Add safe admin copy for the platform limit and run OfferManagement/TicketOffer focused suites.

## Task 5: Cap WhatsApp configuration and customer flow

- [ ] Add Event boundary tests for 50 allowed and 51 rejected, plus a historical Event value above 50 that remains stored until an operator saves a valid replacement.
- [ ] Add LiveView tests asserting the quantity input has `max="50"`, the copy states the allowed range, and a historical value above 50 displays without silent clamping.
- [ ] Add a WhatsApp conversation test with historical/direct Offer and Event caps of 100. Assert the prompt and accepted quantity stop at 50, 51 is rejected, and Checkout independently rejects 51.
- [ ] Enforce the upper bound in `Events.set_whatsapp_max_tickets_per_order/2` with `:platform_max_per_order_exceeded` while retaining the default of 9.
- [ ] Set the form `max` to 50 and show corrective copy for historical values above 50. Keep backend Event validation authoritative.
- [ ] Compute the conversation limit as the minimum of the platform limit, current selected Offer configuration, and current Event WhatsApp cap. Re-read the current Offer from PostgreSQL/Ash rather than treating state data as authority.
- [ ] Run Event, LiveView, and WhatsApp conversation focused suites.

## Task 6: Document the P0-D contract and run gates

- [ ] Add the next feature pack, numbered 0053, with the distinction `50 = purchase ceiling` and `50 != revocation limit`, the page size, keyset query, shared advisory lock, final count, failure/retry semantics, scanner invalidation behavior, no-migration decision, and no refund-provider work.
- [ ] Update Order and TicketIssue state-machine documentation to require zero issued TicketIssues before refund/cancel and to state that the internal page size does not cap revocation correctness.
- [ ] Run all focused suites listed in the feature pack, `mix precommit`, `mix sobelow --exit --compact`, and `git diff --check`.
- [ ] Run differential Dialyzer against base `a35ecfef10da4af75f972c72a2139a4709e45749`; require 0 introduced, 0 changed/worsened, and 0 unresolved warnings.
- [ ] Review the complete diff, confirm there is no migration and no PII in logs/telemetry, push the branch, wait for exact-head GitHub CI, and create a detailed PR. Do not merge it.
