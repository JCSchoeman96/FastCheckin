# VS-09A — Ticket Issuance Contract

**Slice:** VS-09A  
**Status:** Contract (no production issuance in this slice)  
**Last updated:** 2026-06-20  
**Related docs:**

- [ticket_issuance_failure_matrix.md](./ticket_issuance_failure_matrix.md)
- [ticket_issuance_idempotency_keys.md](./ticket_issuance_idempotency_keys.md)
- [policies/PARTIAL_TICKET_ISSUANCE_POLICY.md](./policies/PARTIAL_TICKET_ISSUANCE_POLICY.md)

---

## 1. Purpose

This document is the authoritative contract for converting **verified paid Sales orders** into:

1. existing Ecto `attendees` rows (scanner-visible truth), and
2. Ash `sales_ticket_issues` rows (Sales audit/link/token truth),

without duplicate tickets, hidden side effects, or scanner instability.

VS-09A defines the contract only. VS-09B/VS-09C implement behavior under this contract.

---

## 2. Approved entrypoint

Exactly one orchestration module may coordinate issuance:

```elixir
FastCheck.Tickets.Issuer.issue_order(order_id, opts \\ [])
```

**Module path:** `lib/fastcheck/tickets/issuer.ex`

**Allowed opts (future implementation):**

- `:actor` — system actor map (default system)
- `:correlation_id` — trace id propagated from worker
- `:idempotency_key` — worker-scoped retry key

**Return shapes (future implementation):**

| Result | Meaning |
|---|---|
| `{:ok, %{order_id: id, status: :ticket_issued, issued_count: n}}` | All units completed |
| `{:ok, %{order_id: id, status: :already_issued, issued_count: n}}` | Idempotent retry; no new rows |
| `{:ok, %{order_id: id, status: :partially_issued, issued_count: n, failed_count: f}}` | Some units failed recoverably |
| `{:error, {:invalid_order_state, state}}` | Preconditions failed before customer value |
| `{:error, {:manual_review_required, reason_code}}` | Support must intervene |
| `{:error, {:retryable, reason_code}}` | Transient failure; worker retries |
| `{:error, {:permanent, reason_code}}` | Non-retryable without manual fix |

**Forbidden direct issuers:** controllers, Paystack webhook controllers/workers, LiveViews, WhatsApp handlers, admin manual actions, payment outcome modules.

**Approved caller (future):**

```text
FastCheck.Workers.IssueTicketsWorker
  -> FastCheck.Tickets.Issuer.issue_order(order_id, opts)
```

---

## 3. Transaction model

### Selected model: single `FastCheck.Repo` transaction

Ash Sales resources and Ecto `attendees` share [`FastCheck.Repo`](../../lib/fastcheck/repo.ex). Issuance uses **one database transaction**, not a cross-repo saga.

**Rationale:** Same-repo Ash + Ecto allows atomic Attendee + TicketIssue + Order transition + StateTransition audit in one commit.

### Transaction steps (future VS-09B/C implementation)

```text
Repo.transaction(fn ->
  pg_advisory_xact_lock(order.id)
  reload Order, OrderLines, PaymentAttempt, CheckoutSession
  verify preconditions
  for each deterministic issuance unit:
    create/reuse Attendee (VS-09B)
    create/reuse TicketIssue linked to Attendee (VS-09C)
  transition Order -> ticket_issued | partially_issued | manual_review
  append StateTransition rows
end)
after commit:
  enqueue EventSyncVersionAggregatorWorker (VS-10)
```

### Rules inside the transaction

- No Paystack, Meta, email, or WhatsApp HTTP
- No QR image rendering
- No Redis Lua/key mutation
- No external IO

### Process crash

Mid-transaction crash rolls back all work. Retry starts cleanly from durable order state.

---

## 4. Locking strategy

| Lock | Purpose | Approach |
|---|---|---|
| Order lock | Prevent duplicate workers issuing same order | `pg_advisory_xact_lock(order.id)` inside transaction (same pattern as [`PaymentVerification`](../../lib/fastcheck/sales/payments/payment_verification.ex)) |
| Issuance unit | Prevent duplicate ticket per line quantity slot | DB unique `(sales_order_line_id, line_item_sequence)` on `sales_ticket_issues` |
| Attendee origin | Prevent duplicate Attendee per unit | DB unique `(source, source_reference)` for `fastcheck_sales` (**VS-09B migration**) |
| Ticket code | Prevent duplicate codes | DB unique `ticket_code` on `sales_ticket_issues` |
| TicketIssue attendee | One Sales audit row per Attendee | DB unique `attendee_id` where not null |
| Worker uniqueness | Reduce duplicate work | Oban unique by `sales_order_id` — **correctness is DB constraints, not Oban** |

Duplicate worker execution must return idempotent success or a retry-safe error. Never rely on “worker runs once.”

---

## 5. Issuance unit model

Each `OrderLine` expands deterministically:

```text
for each order_line:
  line_item_sequence = 1..order_line.quantity
```

**Unique unit identity:** `sales_order_line_id + line_item_sequence`

**Recommended Sales origin reference:**

```text
sales:{sales_order_id}:{sales_order_line_id}:{line_item_sequence}
```

**Rules:**

- `line_item_sequence` starts at 1 per order line
- Never derived from runtime row counts (race-prone)
- Retry must compute identical units every time
- Quantity 3 produces exactly 3 units

See [ticket_issuance_idempotency_keys.md](./ticket_issuance_idempotency_keys.md).

---

## 6. Preconditions

Issuance is allowed only when **all** sections below pass. The issuer must not re-verify Paystack or read raw webhook payloads; it requires durable state from VS-07B/VS-07C.

### 6.1 Order preconditions

- Order exists
- Status is `paid_verified` or `fulfillment_queued` (approved state matrix)
- At least one `OrderLine`
- `total_amount_cents` and `currency` already verified at payment time
- Not cancelled, expired (without approved late-payment recovery), refunded, or terminal manual-review
- `source_channel` is server-set approved channel
- Order `event_id` matches all loaded offers and lines (event-scoped-first)

### 6.2 Payment preconditions

- At least one `PaymentAttempt` with `verified_success`
- Verified attempt amount matches `Order.total_amount_cents`
- Verified attempt currency matches `Order.currency`
- Provider reference linked to this order, not reused for another order
- Attempt not `verified_amount_mismatch`, `verified_currency_mismatch`, `failed`, `duplicate`-only, or payment-path `manual_review`

### 6.3 Checkout / inventory preconditions

- `CheckoutSession` is `paid` or approved post-verification fulfillment state
- Inventory hold consumed, **or** VS-07C/VS-14 late-payment inventory recovery recorded success
- Issuer must **not** mutate Redis keys
- Issuer must **not** issue after expired checkout without VS-07C late-payment/manual-review decision

### 6.4 Attendee protection preconditions (VS-02)

- `source` / `source_reference` semantics documented and tested
- Sales-created attendees use `source = "fastcheck_sales"`
- Tickera reconciliation must not overwrite Sales-origin rows
- Scanner acceptance uses attendee `scan_eligibility`; Sales `scanner_status` on TicketIssue is audit-only until VS-15A bridge

### 6.5 Token preconditions (VS-08)

- `FastCheck.Tickets.CodeGenerator` for ticket codes
- `FastCheck.Tickets.QrPayload` / `DeliveryToken` for hash generation
- Plaintext delivery token and QR token **never persisted** — hashes and expiry only
- Dedicated `:ticket_token_pepper` separate from hold pepper

---

## 7. Order state outcomes

| Condition | Order outcome |
|---|---|
| All issuance units completed and linked | `ticket_issued` |
| Some units completed, some recoverably failed | `partially_issued` or `manual_review` per [failure matrix](./ticket_issuance_failure_matrix.md) |
| Preconditions fail before any customer value | stay current or `manual_review` with reason |
| Full issuance detected on retry | keep/mark `ticket_issued` idempotently (`:already_issued`) |
| Duplicate worker after issued | idempotent success; no new Attendee/TicketIssue |

**TicketIssue status (later slices):**

- `pending` → `issued`
- `issued` → `manual_review` (support/investigation only)
- `issued` → `revoked` via VS-15A revocation path only

---

## 8. StateTransition audit

Every issuance outcome records a `sales_state_transitions` row via `StateTransitionSupport.record!/2`.

**Required fields:**

- `entity_type`, `entity_id`
- `from_state`, `to_state`
- `reason`
- `actor_type` = `system` unless manual/admin recovery
- `correlation_id`, `idempotency_key`
- `source` = `issue_tickets_worker` | `tickets_issuer`

**Metadata (sanitized via `Redactor.safe_metadata/1`):**

- `issued_count`, `expected_count`, `failed_count`
- `reason_code` when relevant

Do not put PII, tokens, or `idempotency_key` inside metadata maps (top-level column only).

---

## 9. Worker contract (documented; not implemented in VS-09A)

**Module:** `FastCheck.Workers.IssueTicketsWorker`  
**Path:** `lib/fastcheck/workers/issue_tickets_worker.ex`  
**Queue:** `:ticketing` (config added in a later slice)

**Semantics:**

- Only worker allowed to call `Issuer.issue_order/1`
- Load fresh state every run
- Trust only `order_id`, `correlation_id`, `idempotency_key` in args
- Safe retry forever for transient/recoverable failures
- Never issue from payment/webhook workers
- Never deliver tickets after issuing (delivery is later)
- Enqueue event sync **after commit** only

**Worker output must not include:** buyer phone/email, plaintext tokens, raw Paystack/WhatsApp payloads, authorization URL, access code.

---

## 10. Slice responsibility split

| Slice | Owns |
|---|---|
| **VS-09A** | This contract, failure matrix, idempotency keys, contract stub, contract tests |
| **VS-09B** | Idempotent Ecto Attendee create/reuse; `source=fastcheck_sales`; attendee origin unique migration; scanner-safe fields; **no TicketIssue writes** |
| **VS-09C** | TicketIssue create/reuse; `attendee_id` link; token hashes via VS-08; Order transitions + StateTransition inside Issuer transaction |
| **VS-09D** | Integration/retry/concurrency tests against real Issuer; duplicate worker and partial-failure hardening |

---

## 11. Logging and security

Use `FastCheck.Observability.Redactor` for all issuance logs and transition metadata.

**Never log:** buyer_name, buyer_phone, buyer_email, plaintext QR/delivery tokens, raw Paystack/WhatsApp payloads, access_code, authorization_url.

**Safe to log:** order id, public_reference, correlation_id, idempotency_key (Logger metadata only), issued/failed counts, reason_code.

Do not embed PII in `source_reference`, `ticket_code`, or token hashes.

---

## 12. Known blockers for downstream slices

| Blocker | Owner |
|---|---|
| Partial unique `attendees(source, source_reference)` for `fastcheck_sales` | VS-09B |
| Order Ash actions: `mark_fulfillment_queued`, `mark_ticket_issued`, `mark_partially_issued`, issuance `mark_manual_review` | VS-09C |
| `TicketIssue` create/update actions | VS-09C |
| `IssueTicketsWorker` implementation | After VS-09C |
| Oban `:ticketing` queue config | Worker slice |
| `EventSyncVersionAggregatorWorker` | VS-10 |

---

## 13. VS-09A deliverables checklist

- [x] This contract document
- [x] Failure matrix document
- [x] Idempotency keys document
- [x] Contract-only `FastCheck.Tickets.Issuer` stub (raises until VS-09B)
- [x] Contract tests under `test/fastcheck/tickets/` and `test/fastcheck/workers/`
- [ ] Production issuance (explicitly deferred)
