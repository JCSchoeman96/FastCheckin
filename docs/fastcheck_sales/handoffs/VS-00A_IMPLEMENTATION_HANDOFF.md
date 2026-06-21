# VS-00A Implementation Handoff

## Status

Merged.

PR: #329 — Docs: FastCheck Sales VS-00 planning gates  
Merge commit: `1257501cd8f31e8b577e98f5508addca3818cc2d`  
Implementation commit: `134439656935bbc2b745486172a05d1e46255c63`  
Merged at: 2026-06-15T07:21:41Z  
Branch: `docs/fastcheck-sales-vs00-planning-gates`

VS-00A was merged as part of grouped PR #329. The VS-00A implementation commit
is represented in the squash/merge commit #329 produced on main.

## What Changed

VS-00A added the documentation-only state-machine and failure-policy contract for
FastCheck Sales before Ash resources, migrations, workers, payment handlers,
checkout flows, or ticket issuance logic were implemented.

The slice defined legal transition matrices for seven Sales stateful resources,
forbade generic status mutation, required `StateTransition` audit for every
transition, and documented payment-after-expiry, partial issuance, manual review,
and terminal-state recovery policies.

No runtime code, migrations, Ash resources, workers, routes, controllers,
LiveViews, scanner changes, Android changes, Paystack/Meta clients, Redis scripts,
or executable tests were added.

## Files Changed

- `docs/fastcheck_sales/slices/VS-00A_STATE_MACHINE_AND_FAILURE_POLICY_FINALIZATION.md`
  — slice summary, scope, completion checklist, and RED/GREEN documentation checks.
- `docs/fastcheck_sales/state_machines/STATE_MACHINE_MASTER.md` — global rules,
  actor types, dangerous preconditions, and future test expectations.
- `docs/fastcheck_sales/state_machines/ORDER_STATE_MACHINE.md` — Order lifecycle
  matrix, forbidden transitions, and customer-facing payment truth rule.
- `docs/fastcheck_sales/state_machines/CHECKOUT_SESSION_STATE_MACHINE.md` —
  checkout hold/payment-link lifecycle transitions.
- `docs/fastcheck_sales/state_machines/PAYMENT_ATTEMPT_STATE_MACHINE.md` —
  provider transaction lifecycle transitions.
- `docs/fastcheck_sales/state_machines/PAYMENT_EVENT_PROCESSING_STATE_MACHINE.md`
  — webhook/event processing lifecycle transitions.
- `docs/fastcheck_sales/state_machines/TICKET_ISSUE_STATE_MACHINE.md` — ticket
  validity/issuance lifecycle transitions.
- `docs/fastcheck_sales/state_machines/DELIVERY_ATTEMPT_STATE_MACHINE.md` —
  delivery audit lifecycle transitions.
- `docs/fastcheck_sales/state_machines/CONVERSATION_STATE_MACHINE.md` — WhatsApp/
  customer interaction lifecycle transitions.
- `docs/fastcheck_sales/policies/PAYMENT_AFTER_EXPIRY_POLICY.md` — late verified
  payment behavior after hold/checkout expiry.
- `docs/fastcheck_sales/policies/PARTIAL_TICKET_ISSUANCE_POLICY.md` — retry-safe
  partial issuance and idempotency anchors.
- `docs/fastcheck_sales/policies/MANUAL_REVIEW_POLICY.md` — manual review entry/
  exit actors, required metadata, and forbidden bypasses.
- `docs/fastcheck_sales/policies/TERMINAL_STATE_POLICY.md` — terminal states per
  resource and constrained recovery rules.

Planning context (not implementation truth): `docs/fastcheck_sales/feature_packs/0001_VS-00A_state-machine-and-failure-policy-finalization/VS-00A-FEATURE_PACK.md`.

## Contracts Now Available

- Required transition matrix format for all Sales state machines:

  | From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |

- Generic `update_status` and `update_state` actions are forbidden.
- Every state transition requires `StateTransition` audit.
- Manual admin/operator transitions require a non-empty reason.
- System transitions should preserve `correlation_id`, `request_id`, or
  `idempotency_key` when available.
- Supported actor types in state-machine docs: `system`, `admin`, `operator`,
  `customer_session`.
- Seven state-machine documents exist for:
  `Order`, `CheckoutSession`, `PaymentAttempt`, `PaymentEvent`, `TicketIssue`,
  `DeliveryAttempt`, and `Conversation`.
- Global dangerous-transition preconditions are documented for
  `mark_paid_verified`, `queue_fulfillment`, `mark_ticket_issued`, and
  `revoke_issued_ticket`.
- Paystack webhook payload alone never produces verified payment state.
- Ticket issuance requires verified payment, inventory eligibility, and
  idempotent issuer behavior.
- Customer-facing channels must not deny payment after durable verified payment
  exists.
- Failure policies exist for payment-after-expiry, partial issuance, manual
  review, and terminal-state recovery.
- RED/GREEN documentation checks in the slice doc define acceptance criteria for
  later implementation slices.

## Decisions Applied

- Named actions only; no generic status mutation.
- `StateTransition` audit is mandatory for every transition.
- Manual review is an explicit recovery state with approved target exits only.
- Terminal states require documented admin/system recovery actions with audit
  reason; no destructive rewrites.
- Payment verification authority stays server-side; webhook signals enqueue
  verification rather than directly marking payment verified.
- Late verified payment after hold expiry must re-reserve/consume inventory or
  move to `manual_review`; no blind issuance.
- Partial issuance preserves artifacts for retry; duplicate workers must not
  create duplicate attendees or tickets.
- Dangerous transitions must list side effects and idempotency rules in the
  matrix.
- Documentation-only slice; no runtime enforcement yet.

## Boundaries Still Enforced

- No implementation code in VS-00A.
- No Ash resources, resource actions, or migrations.
- No `StateTransition` persistence schema or runtime writer.
- No Paystack client, webhook controller, initialization, or verification code.
- No Meta/WhatsApp client or conversation runtime.
- No Redis inventory scripts, holds, or reconciliation behavior.
- No checkout workflow, order service, issuer, or delivery workers.
- No Oban workers.
- No LiveView/admin/customer UI.
- No scanner or mobile API changes.
- No Android changes.
- No executable tests added in this slice.

## Tests Added Or Updated

VS-00A did not add executable tests. It added documentation-level RED/GREEN
checks and future test expectations in:

- `docs/fastcheck_sales/slices/VS-00A_STATE_MACHINE_AND_FAILURE_POLICY_FINALIZATION.md`
- `docs/fastcheck_sales/state_machines/STATE_MACHINE_MASTER.md`
- individual state-machine and policy documents under `state_machines/` and
  `policies/`

Later implementation slices must translate the relevant VS-00A contracts into
allow/deny transition tests, idempotent retry tests, and policy enforcement when
they add runtime behavior.

## Verification Reported

PR #329 was a docs-only planning-gate PR. The VS-00A slice checklist in the PR
covered state-machine matrices, forbidden generic mutation, `StateTransition`
audit requirements, and the four failure-policy documents.

From PR #329:

```bash
git status --short --branch
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Results reported at merge:

- `mix format --check-formatted` — exit 0
- `mix compile --warnings-as-errors` — exit 0
- `mix test` — 333 tests, 0 failures, 4 skipped
- Documentation sanity checks for `StateTransition`, server-side verification,
  and related planning-gate terms — pass

The implementation evidence on main shows:

- PR #329 merged successfully.
- Commit `134439656935bbc2b745486172a05d1e46255c63` added the VS-00A state-machine
  and policy documents.
- Merge commit `1257501cd8f31e8b577e98f5508addca3818cc2d` contains the grouped
  VS-00 planning-gate docs.

No runtime test results are associated with VS-00A because the slice was
documentation-only.

## Known Limitations

- VS-00A defines contracts only; later slices implement them in code, migrations,
  Ash actions, workers, and tests.
- VS-00A has no post-merge runtime verification beyond docs presence/content
  checks.
- Actor/event-scoped access enforcement is documented at the state-machine level
  but detailed security policy lives in VS-00B.
- Inventory re-reserve/consume behavior is referenced by policy but detailed
  inventory contracts live in VS-00C.
- Later slices may expand specific policies (for example issuance reason codes)
  without replacing the VS-00A matrix requirement.

## Next Agent Guidance

**Reuse:**

- `docs/fastcheck_sales/state_machines/STATE_MACHINE_MASTER.md` as the global
  Sales transition rules index.
- The per-resource state-machine docs as the authoritative named-action matrices.
- The four policy docs under `docs/fastcheck_sales/policies/` for failure and
  recovery behavior.
- The slice doc RED/GREEN checks when validating whether an implementation slice
  respects VS-00A.

**Do not:**

- Introduce generic `update_status` / `update_state` Ash actions or service helpers.
- Mark payment verified from webhook payload alone.
- Issue tickets before verified payment and inventory eligibility are satisfied.
- Exit `manual_review` or terminal states without explicit named recovery actions,
  audit reason, and approved target state.
- Bypass `StateTransition` audit when implementing transitions in later slices.
- Recreate state-machine rules in ad hoc service code without referencing the
  accepted docs.

**Keep available:**

- All thirteen VS-00A docs listed above must remain the planning contract unless
  an explicit later policy-revision slice owns the change.

## Next Slice

Recommended next slice: **VS-00B — Security, PII, and Token Policy Finalization**

Entry condition:

- VS-00A is merged on `main`.
- All seven state-machine documents and four failure-policy documents exist under
  `docs/fastcheck_sales/state_machines/` and `docs/fastcheck_sales/policies/`.
- Named-action and `StateTransition` audit requirements remain accepted.
- VS-00B should add the security/PII/token contract without weakening VS-00A
  transition or recovery rules.
