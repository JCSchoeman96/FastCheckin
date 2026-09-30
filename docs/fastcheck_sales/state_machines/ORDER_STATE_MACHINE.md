# Order State Machine

## Allowed States

`draft`, `awaiting_payment`, `payment_pending`, `paid_unverified`,
`paid_verified`, `fulfillment_queued`, `ticket_issued`, `partially_issued`,
`issuance_retry_queued`, `manual_review`, `manual_review_held`,
`no_fulfillment_closed`, `cancelled`, `expired`, `refunded`.

## WhatsApp Conversation Restart Classification

The WhatsApp reset guard treats these statuses as active and non-abandonable:

```text
draft
awaiting_payment
payment_pending
paid_unverified
paid_verified
fulfillment_queued
partially_issued
issuance_retry_queued
manual_review
manual_review_held
```

`ticket_issued`, `expired`, `cancelled`, `refunded`, and
`no_fulfillment_closed` are terminal for this guard. `ticket_issued` completes
the purchase flow while the Order remains permanently linked to its
Conversation. `no_fulfillment_closed` is the additional terminal state used
when manual review closes without fulfillment.

## P1-C refund finalization invariant

An Order reaches `refunded` only through the named `finalize_refund` action.
The action requires a durable Refund with accepted full-refund evidence, one
matching `verified_success` PaymentAttempt, completed order-level revocation,
and an authoritative zero issued `TicketIssue` count. Revocation must finish
before financial finalization.

The finalization transaction acquires the existing
`pg_advisory_xact_lock(order_id)`, reloads and rechecks the Order, Refund,
PaymentAttempt, and issued-ticket count, then atomically marks the
PaymentAttempt `refunded`, the Order `refunded`, the Refund `inventory_pending`,
and inserts the unique `RefundInventoryWorker`. It does not call Redis. A
Refund that cannot complete revocation stays in `revocation_manual_review` and
cannot finalize the Order.

## Transition Matrix

| From state | To state | Named action | Actor type | Preconditions | Required side effects | Audit required? | Idempotency rule | Terminal? |
|---|---|---|---|---|---|---|---|---|
| `draft` | `awaiting_payment` | `open_checkout` | `system` | Order has event_id, lines, source_channel, public_reference. | Create/attach checkout intent. | yes | Same public_reference returns existing open order. | no |
| `draft` | `cancelled` | `cancel_draft_order` | `system/admin` | No verified payment and no issued tickets. | Release active hold if present. | yes | Repeated cancel returns cancelled. | yes |
| `draft` | `expired` | `expire_draft_order` | `system` | Order expired before payment start. | Release active hold if present. | yes | Repeated expiry returns expired. | yes |
| `awaiting_payment` | `payment_pending` | `mark_payment_pending` | `system` | Paystack initialization exists or customer was sent payment URL. | Record pending payment metadata. | yes | Same payment reference is idempotent. | no |
| `awaiting_payment` | `paid_unverified` | `record_unverified_payment_signal` | `system` | Webhook or return signal exists; verification not complete. | Persist signal; enqueue verification. | yes | Duplicate signal does not create duplicate attempt. | no |
| `awaiting_payment` | `paid_verified` | `mark_paid_verified` | `system` | Server-side verification succeeds with amount, currency, reference, and event match. | Record paid_at and insert `PaidOrderFulfillmentWorker` in the same Postgres transaction. | yes | Existing verified payment is not downgraded; duplicate verification repairs a missing handoff. | no |
| `awaiting_payment` | `expired` | `expire_awaiting_payment_order` | `system` | Checkout hold expired and no verified payment exists. | Release unconsumed hold. | yes | Repeated expiry returns expired. | yes |
| `awaiting_payment` | `cancelled` | `cancel_awaiting_payment_order` | `admin/system` | No verified payment and no issued tickets. | Release active hold and record reason. | yes | Repeated cancel returns cancelled. | yes |
| `payment_pending` | `paid_unverified` | `record_payment_webhook` | `system` | Webhook stored and signature accepted. | Enqueue server-side verification. | yes | Duplicate webhook remains idempotent. | no |
| `payment_pending` | `paid_verified` | `mark_pending_payment_verified` | `system` | Server-side verification succeeds. | Record paid_at and insert `PaidOrderFulfillmentWorker` in the same Postgres transaction. | yes | Duplicate verification returns verified and repairs a missing handoff. | no |
| `payment_pending` | `manual_review` | `flag_pending_payment_review` | `system/admin` | Provider or local state is inconsistent. | Record reason and customer-safe message status. | yes | Same reason does not create duplicate review loops. | no |
| `payment_pending` | `expired` | `expire_pending_payment_order` | `system` | Hold expired and no verified durable payment exists. | Release hold and preserve payment attempt history. | yes | Existing expired state unchanged. | yes |
| `payment_pending` | `cancelled` | `cancel_pending_payment_order` | `admin/system` | No verified durable payment exists. | Release hold and audit reason. | yes | Existing cancelled state unchanged. | yes |
| `paid_unverified` | `paid_verified` | `verify_unverified_payment` | `system` | Server-side verification succeeds with exact checks. | Record paid_at and insert `PaidOrderFulfillmentWorker` in the same Postgres transaction. | yes | Existing verified state unchanged; duplicate verification repairs a missing handoff. | no |
| `paid_unverified` | `manual_review` | `flag_unverified_payment_review` | `system` | Verification mismatch, provider ambiguity, or missing local ownership. | Record review reason. | yes | Same mismatch is idempotent. | no |
| `paid_verified` | `fulfillment_queued` | `queue_fulfillment` | `system` | Verified attempt amount/currency match the Order; CheckoutSession is paid; exactly one OrderLine exists; its exact inventory hold is consumed. | Set `fulfillment_queued_at` and insert `IssueTicketsWorker` in the same Postgres transaction under the order advisory lock. | yes | Exact consumed holds are accepted on retry; transition and issuer enqueue are idempotent. | no |
| `paid_verified` | `manual_review` | `flag_verified_payment_review` | `system/admin` | Inventory or issuance precondition cannot be safely met. | Preserve verified payment evidence. | yes | Duplicate review preserves original evidence. | no |
| `paid_verified` | `refunded` | `finalize_refund` | `admin/system` | Durable Refund evidence is accepted, exactly one matching verified-success PaymentAttempt exists, revocation is complete, and zero issued TicketIssues remain. | Under the existing Order advisory lock, mark PaymentAttempt refunded, Refund inventory_pending, and insert RefundInventoryWorker in the same transaction. | yes | Matching finalization is idempotent; it cannot bypass revocation or the zero-issued check. | yes |
| `fulfillment_queued` | `refunded` | `finalize_refund` | `admin/system` | Durable Refund evidence is accepted, exactly one matching verified-success PaymentAttempt exists, revocation is complete, and zero issued TicketIssues remain. | Under the existing Order advisory lock, mark PaymentAttempt refunded, Refund inventory_pending, and insert RefundInventoryWorker in the same transaction. | yes | Matching finalization is idempotent; it cannot bypass revocation or the zero-issued check. | yes |
| `issuance_retry_queued` | `refunded` | `finalize_refund` | `admin/system` | Durable Refund evidence is accepted, exactly one matching verified-success PaymentAttempt exists, revocation is complete, and zero issued TicketIssues remain. | Under the existing Order advisory lock, mark PaymentAttempt refunded, Refund inventory_pending, and insert RefundInventoryWorker in the same transaction. | yes | Matching finalization is idempotent; it cannot bypass revocation or the zero-issued check. | yes |
| `manual_review` | `refunded` | `finalize_refund` | `admin/system` | Durable Refund evidence is accepted, exactly one matching verified-success PaymentAttempt exists, revocation is complete, and zero issued TicketIssues remain. | Under the existing Order advisory lock, mark PaymentAttempt refunded, Refund inventory_pending, and insert RefundInventoryWorker in the same transaction. | yes | Matching finalization is idempotent; it cannot bypass revocation or the zero-issued check. | yes |
| `manual_review_held` | `refunded` | `finalize_refund` | `admin/system` | Durable Refund evidence is accepted, exactly one matching verified-success PaymentAttempt exists, revocation is complete, and zero issued TicketIssues remain. | Under the existing Order advisory lock, mark PaymentAttempt refunded, Refund inventory_pending, and insert RefundInventoryWorker in the same transaction. | yes | Matching finalization is idempotent; it cannot bypass revocation or the zero-issued check. | yes |
| `fulfillment_queued` | `ticket_issued` | `mark_ticket_issued` | `system` | All attendee and TicketIssue rows created idempotently. | Enqueue event sync aggregation and, for WhatsApp orders, insert `TicketDeliveryCoordinatorWorker` in the same Postgres transaction. | yes | Duplicate issuer returns existing tickets and repairs a missing WhatsApp coordinator handoff. | yes |
| `fulfillment_queued` | `partially_issued` | `mark_partially_issued` | `system` | Some, but not all, ticket rows or attendee rows exist. | Record partial failure metadata; enqueue retry/review. | yes | Retry links existing rows. | no |
| `fulfillment_queued` | `manual_review` | `flag_fulfillment_review` | `system/admin` | Issuance cannot safely continue automatically. | Record reason and preserve partial artifacts. | yes | Existing review remains. | no |
| `partially_issued` | `ticket_issued` | `complete_partial_issuance` | `system` | Missing ticket artifacts are safely completed. | Enqueue event sync aggregation and, for WhatsApp orders, insert `TicketDeliveryCoordinatorWorker` in the same Postgres transaction. | yes | Existing issued rows reused and the WhatsApp coordinator handoff is restored. | yes |
| `partially_issued` | `manual_review` | `flag_partial_issuance_review` | `system/admin` | Retry cannot safely complete. | Preserve partial artifacts and reason. | yes | Existing review remains. | no |
| `partially_issued` | `refunded` | `finalize_refund` | `admin/system` | Durable Refund evidence is accepted, exactly one matching verified-success PaymentAttempt exists, revocation is complete, and zero issued TicketIssues remain. | Under the existing Order advisory lock, mark PaymentAttempt refunded, Refund inventory_pending, and insert RefundInventoryWorker in the same transaction. | yes | Matching finalization is idempotent; it cannot bypass revocation or the zero-issued check. | yes |
| `ticket_issued` | `refunded` | `finalize_refund` | `admin/system` | Durable Refund evidence is accepted, exactly one matching verified-success PaymentAttempt exists, revocation is complete, and zero issued TicketIssues remain. | Under the existing Order advisory lock, mark PaymentAttempt refunded, Refund inventory_pending, and insert RefundInventoryWorker in the same transaction. | yes | Matching finalization is idempotent; it cannot bypass revocation or the zero-issued check. | yes |
| post-payment eligible state | `cancelled` | `mark_order_cancelled_manual` | `admin` | Admin cancellation completes revocation under the Order advisory lock and confirms zero issued TicketIssues. | Revoke every issued ticket and update scanner visibility before the transition. | yes | Duplicate cancellation action returns cancelled only after the zero-issued invariant is confirmed. | yes |
| `ticket_issued` | `manual_review` | `flag_issued_order_review` | `admin/system` | Support issue requires review without invalidating issued ticket yet. | Record reason; do not mutate scanner validity unless explicit revocation. | yes | Duplicate review preserves issued evidence. | no |
| `manual_review` | `paid_verified` | `retry_paid_fulfillment` | `admin/system` | No prior fulfillment boundary; allowed pre-fulfillment inventory failure reason; one exact verified-success attempt, matching amount/currency, paid CheckoutSession, one OrderLine, and no issued TicketIssue. | Preserve `paid_at`, clear the current failure markers, record `retry_paid_order_fulfillment`, and insert `PaidOrderFulfillmentWorker` in the same Postgres transaction. | yes | State transition prevents a second operator retry; worker remains independently idempotent. | no |
| `manual_review` | approved target | `resolve_manual_review_to_target` | `admin/system` | Target is explicitly allowed by policy and reason exists. `refunded` is not an approved target for this generic action. | Record recovery metadata and target side effects. | yes | Same resolution idempotent by review id. | target-dependent |

| `expired` | `paid_verified` | `recover_expired_paid_order` | `system` | Server-side payment verification succeeds; late recovery re-establishes the exact valid hold; amount, currency, paid session, and one OrderLine match. | Record `paid_at` and insert `PaidOrderFulfillmentWorker` with paid-state and PaymentEvent updates in the same Postgres transaction. Keep inventory held until the worker consumes after commit. | yes | Same recovery key reuses the exact held reservation; duplicate verification restores only a missing worker handoff. | no |

## Forbidden Transitions

- Any transition from `refunded`, `cancelled`, or `expired` without explicit
  admin/system recovery policy.
- `manual_review` to `refunded` through `resolve_manual_review_to_target`.
- Any Order refund transition without a matching durable Refund, accepted full
  Paystack evidence, completed revocation, and zero issued TicketIssues.
- `paid_unverified` to `fulfillment_queued`.
- `payment_pending` to `ticket_issued`.
- Issuing tickets directly from `paid_verified`; inventory consumption and the
  `fulfillment_queued` boundary must happen first.
- Any transition that issues tickets without verified payment.

## Paid Order Fulfillment Runtime

For an active checkout, successful Paystack verification commits
`PaymentAttempt = verified_success`, `Order = paid_verified`,
`CheckoutSession = paid`, and the `PaidOrderFulfillmentWorker` job in one
Postgres transaction. This transaction does not call Redis or enqueue
`IssueTicketsWorker` directly. Repeated verification can restore the handoff
while the Order remains eligible. The established late-payment recovery path
re-establishes a valid held reservation but does not consume it. Late payment
commits the verified attempt, paid Order, paid CheckoutSession, finalized
PaymentEvent, and fulfillment-worker job in one Postgres transaction, just like
an active checkout. If that transaction rolls back, inventory remains held and
can be reused by a verification retry.

`FastCheck.Sales.PaidOrderFulfillment` reloads the attempt and its authoritative
Order, checkout, and single OrderLine. It consumes the hold through
`ReservationLedger` outside a database transaction with the deterministic key
`paid_order_fulfillment:consume:<payment_attempt_id>`. A retry may continue only
when the ledger confirms that the same offer, public Order reference, quantity,
and consumed status match exactly. This also accepts the hold already consumed
by late-payment recovery.

After inventory is confirmed, a Postgres transaction takes the Order advisory
lock, reloads the payment authority, transitions the Order, sets
`fulfillment_queued_at`, and inserts `IssueTicketsWorker`. These writes commit
or roll back together. No consumed inventory is released to compensate for a
later database or queue failure. Redis failures retry; unsafe or exhausted
fulfillment moves the paid Order to `manual_review` while preserving payment
evidence.

## WhatsApp Ticket Delivery Handoff

Issuance creates and links the complete durable `TicketIssue` set before the
Order transitions to `ticket_issued`. For a WhatsApp order, that transition and
the `TicketDeliveryCoordinatorWorker` insert commit in the same Postgres
transaction. A queue insertion failure rolls back the transition and the newly
created issue rows. An issuer replay repairs the coordinator handoff without
creating duplicate TicketIssues.

The coordinator validates the Order's exact `sales_conversation_id` binding
and phone match, then checks that every commercial unit has one deliverable
issued TicketIssue. It pages through the complete issue set with bounded
keyset queries. In a transaction per page, it creates or reuses one
`TicketDeliveryIntent` and inserts its send job. Automatic delivery currently
applies only to WhatsApp source orders.

This ordering covers process loss after Redis consumption: the retry verifies
the exact consumed hold and completes the database transaction. Process loss
after that transaction leaves both `fulfillment_queued` and the issuer job
durable. Manual issuance retry and return-to-queue actions also require
`fulfillment_queued_at`; the return operation inserts its issuer job in the
same transaction as its state transition. If fulfillment retry exhaustion moves
an eligible verified-paid Order to `manual_review`, an operator can use the
audited `retry_paid_order_fulfillment` action to validate authority again and
queue the fulfillment worker in the same transaction as the recovery state
transition. This recovery action does not consume Redis inventory itself and
cannot be used for payment mismatches, unverified attempts, or Orders that
already crossed the fulfillment boundary.

## Customer-Facing Rule

Once verified payment exists, no customer channel may state that payment was not
received. The customer may be told that fulfillment is pending, under review, or
awaiting support.

## P0-D Order Revocation Completeness

Order-level revocation takes the same `pg_advisory_xact_lock(order_id)` used by
`FastCheck.Tickets.Issuer`, reloads the Order after acquiring it, and traverses
all issued TicketIssues by ascending id with bounded keyset pages. The page
size is an implementation detail and does not limit which historical orders
can be revoked.

Each ticket mutation uses a savepoint inside one outer Postgres transaction.
Mobile sync aggregation runs once for the complete set of changed attendees;
an aggregation failure rolls back every page. The transaction finishes with an
authoritative count of issued TicketIssues for that Order. Clean revocation
requires that count to be zero. Attendee cache invalidation runs once after
commit for the complete revoked set.

Admin refund and cancellation flows require an empty failure list and a zero
remaining-issued count before their final state transition. Immediately before
that transition they reacquire the same Order advisory lock, reload the Order,
and check the issued count again. An incomplete attempt stays out of `refunded`
and `cancelled` and follows the existing manual-review path.

## P1-C inventory handoff

After `finalize_refund`, `RefundInventoryWorker` reloads the authoritative
OrderLine and exact hold identity. It releases an exact held hold through
`ReservationLedger` with `refund:release:<refund_id>`, the authoritative
quantity, and an atomic unexpired-hold check, or records `retained_consumed`
for an exact consumed hold without Redis mutation. Missing, expired, malformed,
mismatched, or unverifiable holds move the Refund to `inventory_manual_review`
and keep capacity unavailable. Reconciliation may make capacity available only
for a completed Refund with `released_unconsumed`; `Order = refunded` alone
never changes inventory.

## P0-D Customer Purchase Ceiling

`FastCheck.Sales.PurchaseLimits` defines the platform customer purchase ceiling
of 50 tickets per Order. Checkout validates this before inventory reservation
or commercial writes. Offer actions and Event WhatsApp cap configuration cannot
exceed the same policy; WhatsApp presents the minimum of the platform ceiling,
the current Offer limit, and the current Event limit.

The 50-ticket purchase ceiling does not constrain historical Order quantities,
revocation, refund review, or cancellation review. No OrderLine quantity
constraint or migration is part of P0-D.
