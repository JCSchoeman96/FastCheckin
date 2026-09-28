# P0-D Revocation Completeness and Purchase Ceiling

## Goal

Make order-level revocation complete for historical Orders of any size and set
an absolute limit on new customer purchases.

## Separate runtime laws

```text
50 = platform customer purchase ceiling
50 ≠ revocation correctness limit
```

```text
Revocation page size = implementation and performance detail
Revocation completeness = every issued TicketIssue, regardless of Order size
```

## Order-level revocation

`FastCheck.Tickets.Revocation.revoke_order_tickets/2` acquires the same
`SELECT pg_advisory_xact_lock(order_id)` lock as `FastCheck.Tickets.Issuer`,
then reloads and reauthorizes the Order before making changes. It reads issued
TicketIssues in stable ascending-id keyset pages of 50 using the
`sales_order_id`, `status`, and `id > last_seen_id` predicates. It does not use
OFFSET or load the complete Order ticket set into memory.

All pages run in one outer Postgres transaction. Each TicketIssue uses a
savepoint so a safely classified failure does not discard successful
revocations from the same attempt. A final database count of issued
TicketIssues is authoritative. The result includes
`remaining_issued_count`; clean success requires an empty failure list and a
zero count. Retries traverse only rows that remain issued.

The mobile sync aggregator receives the complete changed attendee set once
inside the transaction. Aggregation failure rolls back every page. Cache
invalidation runs once after commit for all successfully revoked attendees.
Ticket-level audit, scanner invalidation evidence, and safe failure
classifications remain in force.

Admin refund and cancellation marker flows require complete revocation. They
reacquire the same Order advisory lock, reload the Order, and check the
authoritative issued count immediately before the final transition. Incomplete
revocation stays out of `refunded` and `cancelled` and follows the existing
manual-review path. This slice does not call Paystack or implement financial
refunds, provider refund evidence, or inventory restocking.

## Platform customer purchase ceiling

`FastCheck.Sales.PurchaseLimits` owns the platform maximum of 50 tickets per
Order. Checkout rejects larger quantities before inventory reservation,
commercial writes, Redis mutation, or job insertion. Supported Offer create
and update actions reject a `max_per_order` above the ceiling. Event WhatsApp
cap configuration accepts 1 through 50 and returns a stable domain error above
that range; the default remains 9.

WhatsApp computes its customer-facing maximum from the current Event cap, the
current Offer cap, and the platform policy. State data is not authoritative.
Checkout validates the platform policy again. The admin form advertises the
same maximum and preserves historical Event cap values above 50 until an
operator saves a valid replacement.

The ceiling does not restrict configured Event inventory, historical Orders,
TicketIssue persistence, revocation, refund review, or cancellation review.
No OrderLine quantity constraint or database migration is included.

## Verification coverage

Focused regressions cover 50/51/60-ticket revocation, second-page failures and
retry, sync aggregation rollback, issuance/revocation serialization, complete
60-ticket admin refund and cancellation, scanner visibility, checkout side
effects at the 51-ticket boundary, direct and managed Offer actions, Event cap
configuration, WhatsApp effective quantity, and the dashboard cap form.

The existing `sales_ticket_issues(sales_order_id, status)` index remains in
place. The query stays scoped to one Order and bounded by the primary-key
cursor; no index migration is added.
