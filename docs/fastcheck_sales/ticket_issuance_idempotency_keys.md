# Ticket Issuance Idempotency Keys

**Authority:** [VS-09A_ticket_issuance_contract.md](./VS-09A_ticket_issuance_contract.md)  
**Last updated:** 2026-06-20

Maps logical idempotency keys to database constraints and issuance units. Correctness comes from **DB constraints + deterministic units**, not Oban “run once.”

---

## 1. Logical idempotency keys

| Key | Scope | Purpose |
|---|---|---|
| `sales_order_id` | Order | Worker args; advisory lock target |
| `sales_order_line_id` | Order line | Issuance unit parent |
| `line_item_sequence` | Per line quantity slot | Deterministic unit index `1..quantity` |
| `ticket_code` | Global ticket identity | Scanner-visible code uniqueness |
| `attendee_sales_origin_reference` | Attendee row | `source` + `source_reference` for Sales origin |
| `correlation_id` | Trace | StateTransition audit; worker propagation |
| `idempotency_key` | Worker retry | Oban args; StateTransition top-level column |
| Order `public_reference` | External reference | Human/support correlation |
| Payment `(provider, provider_reference)` | Payment | Precondition gate; not issuance unit key |

---

## 2. Deterministic issuance units

```text
for each sales_order_line:
  for line_item_sequence in 1..order_line.quantity:
    unit_id = {sales_order_line_id, line_item_sequence}
    origin_reference = "sales:{sales_order_id}:{sales_order_line_id}:{line_item_sequence}"
```

**Rules:**

- `line_item_sequence` is **never** `count(existing_rows) + 1`
- Retry recomputes the same unit set from order lines
- Quantity N ⇒ exactly N units per line

**Alternative origin format (allowed if documented in VS-09B):**

```text
sales:{order_public_reference}:{order_line_line_number}:{line_item_sequence}
```

Pick one format in VS-09B; do not mix per event.

---

## 3. Database constraints

### 3.1 Already present (verified VS-01G)

| Table | Constraint | Index name |
|---|---|---|
| `sales_orders` | unique `public_reference` | `sales_orders_public_reference_uidx` |
| `sales_orders` | unique `idempotency_key` where not null | `sales_orders_idempotency_key_uidx` |
| `sales_order_lines` | unique `(sales_order_id, line_number)` | `sales_order_lines_order_line_number_uidx` |
| `sales_payment_attempts` | unique `(provider, provider_reference)` | `sales_payment_attempts_provider_reference_uidx` |
| `sales_ticket_issues` | unique `ticket_code` where not null | `sales_ticket_issues_ticket_code_uidx` |
| `sales_ticket_issues` | unique `(sales_order_line_id, line_item_sequence)` | `sales_ticket_issues_order_line_sequence_uidx` |
| `sales_ticket_issues` | unique `attendee_id` where not null | `sales_ticket_issues_attendee_id_uidx` |
| `sales_ticket_issues` | unique `qr_token_hash` where not null | `sales_ticket_issues_qr_token_hash_uidx` |
| `sales_ticket_issues` | unique `delivery_token_hash` where not null | `sales_ticket_issues_delivery_token_hash_uidx` |
| `attendees` | unique `sales_ticket_issue_id` where not null | `attendees_sales_ticket_issue_id_uidx` |

### 3.2 Gap — VS-09B must add

| Table | Required constraint | Status |
|---|---|---|
| `attendees` | partial unique `(source, source_reference)` where `source = 'fastcheck_sales'` and `source_reference is not null` | **Missing** — VS-02 added non-unique `attendees_source_source_reference_idx` only |

Without this index, duplicate Attendee rows are possible under concurrent workers despite advisory locks if logic regresses.

---

## 4. Duplicate worker behavior

```text
Oban uniqueness by sales_order_id  -> reduces duplicate job noise (not correctness)
pg_advisory_xact_lock(order.id)    -> serializes concurrent issuers per order
DB unique constraints              -> correctness layer for units, codes, attendee links
```

**Expected duplicate-worker outcomes:**

| State when worker runs | Result |
|---|---|
| Order already `ticket_issued` | `{:ok, status: :already_issued}` |
| Partial units persisted | Retry completes missing units/links |
| Another worker holds advisory lock | Wait or retry (`:retryable`) |

Never delete successful partial units on retry.

---

## 5. Idempotent return rules

| Detected state | Return |
|---|---|
| All units issued and linked | `:ticket_issued` or `:already_issued` |
| Some units issued | `:partially_issued` with counts |
| Unrecoverable conflict | `{:error, {:manual_review_required, reason_code}}` |

Order already `ticket_issued` must **not** return an error that causes infinite retry loops.

---

## 6. Worker idempotency args

Future `IssueTicketsWorker` args (contract):

```elixir
%{
  "sales_order_id" => order_id,
  "correlation_id" => correlation_id,
  "idempotency_key" => idempotency_key
}
```

Worker must reload fresh order/payment/checkout state; never trust stale embedded snapshots in args.

---

## 7. Redis / cache

- No Redis keys mutated by Issuer
- No Cachex layer for issuance idempotency
- Inventory consume/recovery state read from durable CheckoutSession / VS-07C outcomes only

---

## 8. Query-path indexes (issuance loads)

Use indexed paths only:

- Order by `id` or `public_reference`
- OrderLines by `sales_order_id` (`sales_order_lines_sales_order_id_idx`)
- PaymentAttempts by `sales_order_id` + status (`sales_payment_attempts_sales_order_id_status_idx`)
- CheckoutSession by `sales_order_id` (unique)
- TicketIssues by `sales_order_id` or `sales_order_line_id`
- Batch fulfillment enqueue (future): `sales_orders_status_fulfillment_queued_at_idx`

Do not scan full tables for recovery.
