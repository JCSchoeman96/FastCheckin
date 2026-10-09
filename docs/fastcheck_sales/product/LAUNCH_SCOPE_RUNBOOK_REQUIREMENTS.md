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
- Dashboard Sales Event grants and access recovery.

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

## Dashboard Sales Access

- Configure `DASHBOARD_ALLOWED_EVENT_IDS` with the positive integer Event IDs
  the dashboard identity may operate.
- A missing or blank value leaves Sales access empty. A malformed nonblank value
  prevents application startup; do not repair it by deleting invalid entries
  from a mixed list.
- After changing the configured allowlist, restart the release and verify the
  intended Event A succeeds while an ungranted Event B is unavailable across
  Sales views and actions.
- General Event administration/sync, CSV exports, scanner, and occupancy retain
  a separate BrowserAuth event-isolation requirement until that follow-up is
  implemented.

## Ingress logging evidence (secure ticket launch gate)

Railway/request-edge raw path logging is confirmed and may remain enabled.

The secure-ticket ingress launch gate requires proof that the **supported** ticket
flow does not place a valid delivery bearer in the HTTP request target.

Supported production flow:

- Outbound link: `/t#<delivery-token>`
- Bootstrap request target: `/t`
- Exchange request target: `/t/session`, bearer in `POST` body
- Authorized reads: `/t/view/:ticket_issue_id` and optional `/t/view/:ticket_issue_id/pdf`
- Legacy `/t/:token` and `/t/:token/pdf` are rejection-only sinks

A legacy or attacker-controlled arbitrary path may still appear in raw path logs;
that does not constitute supported-flow bearer leakage.

P1E-H production evidence on 2026-10-09 proved:

- Positive-control legacy path was visible in Railway HTTP logs
- Fragment marker was absent from request paths
- Body marker was absent from request paths
- Both markers were absent from bounded application/service logs

Durable record: [P1E Secure Ticket Ingress Evidence](../runbooks/P1E_SECURE_TICKET_INGRESS_EVIDENCE.md).

```text
INGRESS_REQUEST_LOGGING_SAFE=PASS
P1E_INGRESS_BLOCKER=CLEARED
```

## Deferred Web Checkout Runbook

Public web checkout runbooks are deferred with `web_checkout_sales`.
