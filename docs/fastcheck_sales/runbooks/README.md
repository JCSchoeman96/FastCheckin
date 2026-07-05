# FastCheck Sales Launch Runbooks

This directory contains the VS-23 launch readiness pack for the completed
FastCheck Sales feature chain.

## Launch Scope

- Primary launch path: WhatsApp-first paid core.
- Secondary paths allowed before launch: internal pilot sales and
  admin-assisted sales.
- Deferred path: public web checkout. Do not include public web checkout in the
  first production launch.

VS-22 E2E tests are the launch-flow source of truth. VS-21B `OpsMetrics` and
`AuditViews` are the launch operator visibility surface.

VS-24E is the pre-wallet production-readiness evidence pack. It validates the
existing WhatsApp -> Paystack -> ticket issuance -> secure ticket link ->
secure ticket page -> dashboard/manual PDF download -> scanner -> verified
resend loop before VS-25 Apple Wallet or Google Wallet work starts.

## Runbook Index

- [VS-23B Final Core Launch Runbook](./VS-23B_FINAL_CORE_LAUNCH_RUNBOOK.md)
- [VS-23C Final WhatsApp Launch Runbook](./VS-23C_FINAL_WHATSAPP_LAUNCH_RUNBOOK.md)
- [Sandbox Dress Rehearsal](./SANDBOX_DRESS_REHEARSAL.md)
- [VS-24E Production Checkout And Ticket Delivery Smoke Test](./VS-24E_PRODUCTION_CHECKOUT_TICKET_DELIVERY_SMOKE_TEST.md)
- [VS-24E Failure Matrix](./VS-24E_FAILURE_MATRIX.md)
- [VS-24E Optional Low-Value Production Smoke](./VS-24E_PRODUCTION_LOW_VALUE_SMOKE.md)
- [Incident Response](./INCIDENT_RESPONSE.md)
- [Rollback and Pause Sales](./ROLLBACK_AND_PAUSE_SALES.md)
- [Go/No-Go Checklist](./GO_NO_GO_CHECKLIST.md)
- [Post-Launch Monitoring](./POST_LAUNCH_MONITORING.md)

## Operator Surfaces

- Ops Dashboard: `/dashboard/sales/ops`
- Audit Timeline: `/dashboard/sales/audit/:entity_type/:entity_id`
- Manual Review: `/dashboard/sales/reviews`
- Order Operations: `/dashboard/sales/orders/:id`
- Admin-Assisted Checkout: `/dashboard/sales/checkout/:event_id`
- Internal Pilot Checkout: `/dashboard/sales/internal-pilot/checkout/:event_id`

## Authority Boundaries

- Redis `ReservationLedger` is the hot inventory authority for checkout holds.
- Paystack server-side verification is the payment authority.
- Backend ticket issuance is the ticket authority.
- Mobile scan acceptance remains server-authoritative.
- WhatsApp is the primary customer interface, not payment or ticket authority.
