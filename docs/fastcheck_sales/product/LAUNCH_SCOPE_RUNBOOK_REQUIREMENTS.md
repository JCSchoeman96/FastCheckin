# Launch Scope Runbook Requirements

## Core Runbooks Required Before Paid Launch

- Sales core readiness.
- Paystack sandbox/live verification.
- Inventory health and Redis reconciliation.
- Ticket issuance retry/partial failure.
- Delivery failure and resend.
- Scanner-safe revocation.
- PII/log-redaction incident response.
- Manual review operations.

## WhatsApp Launch Runbooks Required

- Meta Cloud API webhook verification.
- Inbound dedupe and replay handling.
- WhatsApp 24-hour service window handling.
- Approved template fallback.
- Payment-pending customer messaging.
- Ticket delivery/resend over WhatsApp.

## Secondary Path Runbooks Required Before First Launch

For internal pilot and admin-assisted sales:

- How to create controlled checkout/order flows.
- How to verify Paystack transaction state.
- How to handle manual review.
- How to revoke/refund and confirm scanner visibility.

## Deferred Web Checkout Runbook

Public web checkout runbooks are deferred with `web_checkout_sales`.
