# Rollback And Pause Sales

## Goal

Pause new sales safely without corrupting inventory, payment, tickets, scanner
state, or WhatsApp conversations.

## Safe Pause Order

1. Pause new customer entrypoints.
2. Pause WhatsApp outbound checkout/payment-link creation if needed.
3. Pause admin-assisted checkout creation at `/dashboard/sales/checkout/:event_id`.
4. Pause internal pilot checkout creation at
   `/dashboard/sales/internal-pilot/checkout/:event_id`.
5. Hide or disable any public-facing launch links if they exist.
6. Keep operator access to `/dashboard/sales/ops`, `/dashboard/sales/reviews`,
   and order/audit pages available.

## What Must Continue Running

- Paystack webhook ingestion at `POST /api/sales/paystack/webhook`.
- Payment verification workers.
- Ticket issuance recovery.
- Checkout expiry cleanup.
- Manual review operations.
- Refund/revocation safety.
- Scanner/mobile sync and scan acceptance.
- Audit Timeline reads.
- Ops Dashboard reads.

Stopping these recovery paths can strand paid customers, duplicate support work,
or leave revoked tickets scannable.

## What Must Not Be Manually Edited

- Do not delete or rewrite `sales_payment_events`.
- Do not manually mark a `sales_payment_attempt` verified.
- Do not manually create or duplicate `sales_ticket_issues`.
- Do not manually edit `attendees` scanner-visible fields.
- Do not delete `attendee_invalidation_events`.
- Do not delete `sales_delivery_attempts`.
- Do not delete `sales_state_transitions`.
- Do not manually change Redis inventory unless following an approved inventory
  recovery procedure.
- Do not paste payment links, ticket links, tokens, access codes, phone numbers,
  or email addresses into public incident notes.

## Verification After Pause

- Open `/dashboard/sales/ops`.
- Confirm no new checkout sessions are being created.
- Confirm existing payment webhooks continue to arrive.
- Confirm verified payments continue toward issuance or manual review.
- Confirm checkout expiry cleanup continues to release stale holds.
- Confirm scanner/mobile sync remains available.
- Confirm manual review queue is assigned and being worked.

## Resume Criteria

- Root incident is resolved.
- Ops Dashboard is available.
- Audit Timeline is available.
- Paystack webhook and verification path are healthy.
- Redis inventory matches expected offer state.
- Manual review backlog is understood and assigned.
- WhatsApp outbound path is healthy if resuming WhatsApp.
- Launch owner signs off.

