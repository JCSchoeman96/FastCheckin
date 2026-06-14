# FastCheck Sales Feature Planning Pack — VS-11 Secure Ticket Page

**Pack ID:** `0031_VS-11_secure-ticket-page`  
**Slice:** `VS-11`  
**Slice name:** Secure Ticket Page  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation planning pack  
**Primary area:** Ticket access / Secure customer page / Token verification / QR display boundary  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0031_VS-11_secure-ticket-page`  
**Depends on:** VS-08, VS-09A, VS-09B, VS-09C, VS-09D, VS-10, VS-00B, VS-01D, VS-01F, VS-01G, VS-21A  
**Blocks:** VS-12, VS-15A, VS-15B, VS-19, VS-20, VS-22, VS-23B, VS-23C

**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

Create the customer-facing secure ticket page foundation for Sales-issued tickets.

This slice gives a customer a safe browser page for one issued ticket, accessed through a short/random delivery token from VS-08/VS-09C.

The page must display only the minimum ticket information needed by the buyer/scanner operator:

```text
event name
attendee/display name if available
ticket type
QR/ticket code display payload
ticket validity state
basic help text
```

This slice must not deliver tickets by WhatsApp/email yet. Delivery attempts come later.

---

## 2. FastCheckin Grounding

The implementation must follow the current FastCheckin runtime shape:

```text
Phoenix app: FastCheck
Router: FastCheckWeb.Router
Attendee schema: FastCheck.Attendees.Attendee
Scanner mutation path: FastCheck.Attendees.Scan
Mobile sync path: FastCheckWeb.Mobile.SyncController
Security headers: FastCheckWeb.Plugs.SecurityHeaders
```

Current repo facts that matter:

```text
1. Router already has browser and API pipelines.
2. Browser routes use CSRF/session/security headers and rate limiting.
3. Mobile routes already expose attendee sync-down and scan upload.
4. Attendee scanner truth is currently event_id + ticket_code.
5. Attendee rows carry scan_eligibility, where not_scannable is scanner-denied.
6. Existing CSP allows img-src self/data/https, which is relevant for QR rendering choices.
```

Implementation must add the secure ticket page to FastCheckin, not to `vg_app`.

---

## 3. Ultimate Outcome

After this slice:

```text
A customer with a valid ticket delivery token can open /t/:token or the final chosen route.
The server verifies the token hash against Sales.TicketIssue.
The server loads the linked Attendee and Event through existing FastCheckin schemas.
The page displays a QR/ticket payload that the current scanner can accept.
Expired/revoked/not_scannable tickets do not expose a usable QR.
Invalid tokens return a safe generic not-found/expired response.
All sensitive tokens remain hash-only at rest.
No delivery, resend, WhatsApp, email, Paystack, inventory, or scanner mutation behavior is added.
```

---

## 4. Scope

### In scope

```text
Add public secure ticket route.
Add secure ticket controller or LiveView, preferring controller/static render unless LiveView is needed.
Implement token lookup by hashed delivery token.
Verify token expiry, revocation, ticket issue status, attendee linkage, and attendee scan_eligibility.
Render safe ticket information.
Render QR payload using the scanner-compatible ticket_code or approved qr_token contract from VS-08.
Set no-store/private response headers.
Rate-limit invalid token attempts using the existing rate limiter path or a narrow plug.
Add security-focused tests.
```

### Out of scope

```text
No WhatsApp delivery.
No email delivery.
No DeliveryAttempt creation.
No resend flow.
No Paystack behavior.
No inventory mutation.
No order checkout behavior.
No Attendee creation.
No TicketIssue creation.
No scanner check-in behavior changes.
No mobile sync API response-shape changes.
No admin dashboard.
No refund/revocation operations beyond read-only validity display.
```

---

## 5. Recommended Routes and Files

### Route

Preferred route:

```elixir
scope "/", FastCheckWeb do
  pipe_through :browser

  get "/t/:token", SecureTicketController, :show
end
```

Reason:

```text
The ticket page must be accessible without login through possession of a high-entropy delivery token.
It should still pass through existing browser security headers and rate limiting.
It should not require a session-authenticated dashboard/scanner user.
```

Alternative if controller naming conflicts:

```text
FastCheckWeb.TicketPageController
FastCheckWeb.Sales.TicketPageController
FastCheckWeb.CustomerTicketController
```

Prefer the name that matches existing FastCheckWeb naming style.

### Backend files

Expected files:

```text
lib/fastcheck/sales/ticket_page.ex
lib/fastcheck_web/controllers/secure_ticket_controller.ex
lib/fastcheck_web/controllers/secure_ticket_html.ex
lib/fastcheck_web/controllers/secure_ticket_html/show.html.heex
```

Alternative LiveView only if project conventions require it:

```text
lib/fastcheck_web/live/secure_ticket_live.ex
```

### Tests

Expected tests:

```text
test/fastcheck/sales/ticket_page_test.exs
test/fastcheck_web/controllers/secure_ticket_controller_test.exs
```

---

## 6. Domain Rules

### Token lookup

The raw route token must never be stored in plaintext.

Flow:

```text
raw token from route
  -> normalize/validate format
  -> hash with VS-08-approved token hashing function
  -> lookup Sales.TicketIssue by delivery_token_hash
  -> verify expiry/revocation/status
  -> load linked Attendee and Event
  -> render safe ticket page
```

Rules:

```text
Do not log the raw token.
Do not return whether the token existed.
Do not expose delivery_token_hash.
Do not expose qr_token_hash.
Do not expose provider payloads, order internals, payment attempts, or buyer PII beyond display fields explicitly needed.
```

### Valid display states

The page should classify a ticket into one of these customer-safe states:

```text
valid
expired_link
ticket_revoked
ticket_not_scannable
ticket_not_ready
not_found
```

Behavior:

| State | Page behavior |
|---|---|
| `valid` | Show event/ticket info and QR/ticket code payload. |
| `expired_link` | Do not show QR; show support-safe message. |
| `ticket_revoked` | Do not show QR; show revoked/cancelled support-safe message. |
| `ticket_not_scannable` | Do not show QR; show no-longer-valid support-safe message. |
| `ticket_not_ready` | Do not show QR; show ticket is not ready yet. |
| `not_found` | Generic not-found/expired message; do not reveal token status. |

### Attendee/scanner compatibility

Current scanner compatibility must remain based on existing FastCheckin attendee truth.

Rules:

```text
Valid display requires linked Attendee exists.
Valid display requires Attendee.scan_eligibility is nil or "active".
Valid display requires Attendee.payment_status is scanner-valid according to existing scanner behavior.
QR payload must match what current scanner can scan.
Do not alter FastCheck.Attendees.Scan.
Do not add a new scanner API endpoint.
Do not make the customer page the scanner authority.
```

---

## 7. QR Rendering Boundary

Preferred implementation:

```text
Server generates QR image/SVG from approved payload.
The QR is rendered inline or as data URI only if CSP permits it.
No third-party QR generation service.
No browser-side QR dependency unless already approved.
```

If a QR library is not already present:

```text
Do not add a heavy dependency blindly.
Use the smallest maintained Elixir QR library only if approved by the repo dependency policy.
Alternatively render a fallback text ticket_code in VS-11 and defer QR rendering to a tiny follow-up if dependency review is required.
```

Payload rule:

```text
The QR payload must be the scanner-compatible ticket_code unless VS-08 explicitly selected a different scanner-accepted qr_token.
```

Security rule:

```text
Do not include buyer phone, buyer email, order ID, payment reference, provider reference, or delivery token in the QR payload.
```

---

## 8. Response Headers and Caching

Secure ticket responses must be private and non-cacheable by shared caches.

Set or verify:

```text
cache-control: no-store, private
pragma: no-cache
x-robots-tag: noindex, nofollow
referrer-policy: no-referrer or strict-origin-when-cross-origin, matching existing policy where appropriate
```

Do not allow CDN/browser long caching of token-bearing pages.

If QR images are rendered through a separate route:

```text
The QR route must require the same token validation or a short-lived derived nonce.
Do not expose QR by stable public ticket_issue_id.
Do not cache QR images publicly.
```

---

## 9. Rate Limiting and Abuse Protection

Token-bearing route must be protected against guessing and scraping.

Use existing FastCheckin rate limiter where possible.

Add a narrow route-specific rule if needed:

```text
key = client_ip + normalized_path_family
invalid-token attempts get stricter limits than successful ticket page views
avoid logging raw token in limiter keys
```

Failure behavior:

```text
Invalid/expired/revoked tokens return safe HTML with 404 or 410 style status.
Do not redirect repeatedly.
Do not leak token existence through different technical error shapes.
```

---

## 10. Performance and Scaling Review

### Data placement

```text
TicketIssue token metadata: Postgres durable Sales truth.
Attendee/Event display data: Postgres durable FastCheckin truth, existing cache allowed for Event/Attendee reads.
QR image: generated per request or cached only privately/short TTL in process if safe.
No Redis inventory behavior.
No browser persistent storage.
No CDN public caching.
```

### Hot/warm/cold guidance

```text
Hot: existing ETS attendee/event cache may be used for event/attendee lookup if it does not bypass token validation.
Warm: no Redis required for this slice; optional rate-limit storage remains existing PlugAttack/ETS path.
Cold: TicketIssue lookup by delivery_token_hash in Postgres.
```

### Indexes

Required indexes:

```text
unique or indexed Sales.TicketIssue.delivery_token_hash
index Sales.TicketIssue.delivery_token_expires_at
index Sales.TicketIssue.attendee_id
index Sales.TicketIssue.ticket_code or qr_token_hash if used for lookup/audit
existing attendees unique(event_id, ticket_code)
```

### Latency target

```text
P95 page render should be sub-100ms excluding QR generation if data is cached.
No broad joins over orders/payments.
No full attendee scans.
No loading all TicketIssue rows.
```

---

## 11. Security and PII Rules

```text
Never log route token.
Never log token hash unless explicitly redacted/truncated.
Never expose buyer phone/email unless explicitly approved for the customer page.
Never expose payment reference or Paystack provider reference.
Never expose internal order/payment state names.
Never expose raw QR token if the scanner does not require it.
Use generic responses for invalid tokens.
Use constant-ish behavior where practical to avoid obvious token enumeration signals.
```

Display fields allowed by default:

```text
event.name
attendee.first_name
attendee.last_name
ticket_type
ticket_code as QR/text payload only when valid
basic validity/support text
```

---

## 12. RED/GREEN Test Plan

### RED tests first

```text
RED: valid delivery token renders ticket page with event name, attendee display name, ticket type, and QR/text code.
RED: raw delivery token is not stored in TicketIssue.
RED: invalid token returns generic not-found/expired page without leaking existence.
RED: expired delivery token does not show QR/ticket code.
RED: revoked TicketIssue does not show QR/ticket code.
RED: linked Attendee with scan_eligibility="not_scannable" does not show QR/ticket code.
RED: unissued/not-ready TicketIssue does not show QR/ticket code.
RED: page sets no-store/private/noindex headers.
RED: route does not require dashboard/scanner login.
RED: route is rate-limited by existing browser/rate limiter path.
RED: logs do not contain raw token, delivery_token_hash, qr_token_hash, payment reference, buyer phone, or buyer email.
RED: secure page does not mutate Attendee, Order, PaymentAttempt, PaymentEvent, DeliveryAttempt, or Redis inventory.
RED: scanner tests still pass unchanged.
RED: mobile sync tests still pass unchanged.
```

### GREEN target

```text
GREEN: FastCheckWeb.SecureTicketController.show/2 or equivalent renders safe ticket page.
GREEN: FastCheck.Sales.TicketPage verifies token and returns customer-safe display struct.
GREEN: QR/text payload is only rendered for valid, scannable, issued tickets.
GREEN: all invalid states use safe non-leaking messaging.
GREEN: no forbidden side effects are introduced.
```

---

## 13. Failure Modes

| Failure | Required handling |
|---|---|
| Token malformed | Return generic not-found/expired response; no log token. |
| Token not found | Same as malformed. |
| Token expired | No QR; customer-safe expired link message. |
| TicketIssue revoked | No QR; revoked/cancelled message. |
| Attendee missing | No QR; ticket not ready/support message; emit safe telemetry. |
| Attendee not_scannable | No QR; no-longer-valid message. |
| Event missing/archived | No QR; event unavailable/support message. |
| QR generation fails | Render text fallback only if scanner can accept text ticket_code; otherwise ticket temporarily unavailable. |
| Abuse/high invalid volume | Rate limit; no token details in logs. |

---

## 14. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement the VS-11 Secure Ticket Page in `JCSchoeman96/FastCheckin`. |
| Objective | Allow customers with valid delivery tokens to view a safe ticket page and QR/ticket payload, while preserving hash-only token storage, scanner compatibility, and no delivery side effects. |
| Output | Add route in `lib/fastcheck_web/router.ex`; add `FastCheck.Sales.TicketPage` or equivalent service; add `FastCheckWeb.SecureTicketController` and HEEx template or equivalent; add tests under `test/fastcheck/sales/` and `test/fastcheck_web/controllers/`; no scanner/payments/delivery/inventory changes. |
| Note | Use FastCheckin repo truth: app root is `FastCheck`; current router has browser/api/mobile routes; Attendee scanner truth is `event_id + ticket_code`; `scan_eligibility="not_scannable"` must suppress QR; browser CSP currently permits `img-src 'self' data: https:`. Do not store raw tokens. Hash route token before lookup. Required index: `sales_ticket_issues.delivery_token_hash`; recommended indexes: `delivery_token_expires_at`, `attendee_id`. Set `cache-control: no-store, private`, `pragma: no-cache`, `x-robots-tag: noindex,nofollow`. No Paystack, WhatsApp, DeliveryAttempt, Attendee mutation, scanner mutation, mobile API shape change, Redis inventory mutation, or order/payment state changes. If QR dependency is not approved, use text fallback and mark QR library as blocked for review. Performance: no full-table scans; token lookup must be indexed; page p95 sub-100ms excluding QR generation; no public/CDN caching. |
| Success | A valid token renders only safe ticket data and scanner-compatible QR/text; invalid/expired/revoked/not_scannable tickets never expose a usable code; scanner and mobile sync tests remain unchanged and green. |

---

## 15. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-11 — Secure Ticket Page in JCSchoeman96/FastCheckin.

Use the current FastCheckin repo as truth:
- app/module root: FastCheck
- router: lib/fastcheck_web/router.ex
- attendee schema: lib/fastcheck/attendees/attendee.ex
- scanner mutation path: FastCheck.Attendees.Scan
- mobile sync path: FastCheckWeb.Mobile.SyncController
- existing browser security headers/rate limiter must stay active

Implement a public possession-token ticket page:
1. Add a browser route such as GET /t/:token.
2. Hash the raw route token using the VS-08 token-hashing contract.
3. Lookup Sales.TicketIssue by delivery_token_hash using an indexed query.
4. Verify token expiry, TicketIssue status/revocation, linked Attendee, linked Event, and Attendee scan_eligibility.
5. Render event name, attendee display name, ticket type, and scanner-compatible QR/text payload only when valid.
6. For invalid/expired/revoked/not_scannable/not-ready states, do not render QR or usable ticket_code.
7. Add no-store/private/noindex response headers.
8. Ensure invalid token attempts are covered by existing rate limiting or a narrow route-specific limiter.

Do not:
- log raw tokens or token hashes
- store raw tokens
- expose payment/order/provider internals
- send WhatsApp/email
- create DeliveryAttempt rows
- mutate Attendee/Order/PaymentAttempt/PaymentEvent
- change scanner behavior
- change mobile sync response shape
- mutate Redis inventory
- add heavy QR dependencies without dependency review

Write RED tests first, then implement the minimal code needed to pass them.
```

---

## 16. Human Review Checklist

```text
[ ] Route is public but protected by possession token and rate limiting.
[ ] Raw delivery token is never stored or logged.
[ ] Token lookup uses hash and indexed query.
[ ] Expired/revoked/not_scannable/not-ready tickets do not show QR/ticket code.
[ ] Valid page shows only safe fields.
[ ] QR payload is scanner-compatible and contains no PII/payment data.
[ ] Response headers are no-store/private/noindex.
[ ] Existing browser security headers remain active.
[ ] No DeliveryAttempt, WhatsApp, email, Paystack, Redis inventory, or scanner mutation added.
[ ] Scanner tests still pass.
[ ] Mobile sync tests still pass.
[ ] Log redaction tests pass.
```

---

## 17. Next Slice

```text
VS-12 — Admin Sales Dashboard
```
