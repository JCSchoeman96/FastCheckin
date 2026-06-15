# FastCheck Sales Risk Register

## Scope

This register tracks architecture and product risks that must be handled before
runtime implementation begins. Severity `P0` means the risk can compromise paid
launch safety, customer trust, payment integrity, scanner validity, or privacy.

| Risk | Severity | Required handling | Owning gate |
|---|---:|---|---|
| WhatsApp becomes business-logic owner | P0 | WhatsApp must call Sales/Checkout services only. | VS-00D |
| Web/admin checkout bypasses Redis inventory | P0 | Every channel must use `ReservationLedger`. | VS-00C, VS-00D |
| Payment webhook treated as payment authority | P0 | Paystack server-side verification required before verified payment state. | VS-00A, VS-00B |
| Ticket issued before verified payment | P0 | Issuance depends on verified payment and accepted transition matrix. | VS-00A |
| Duplicate worker creates duplicate tickets | P0 | Issuance idempotency required in VS-09A through VS-09D. | VS-00A |
| Redis loss causes oversell | P0 | Redis recovery and reconciliation contract required before checkout work. | VS-00C |
| Refunded ticket still scans | P0 | Scanner-safe revocation is required before paid launch. | VS-00, VS-00D |
| Raw provider payload leaks PII | P0 | Raw payload access, retention, and redaction policy required. | VS-00B |
| Agents start VS-01A before gates | P0 | Roadmap and docs must mark implementation blocked. | VS-00 |
| Launch scope unclear | P0 | VS-00D must lock channel priority and launch scope. | VS-00D |
| Operators see all events by default | P0 | First release must use `event_scoped_first` access, not role-only access. | VS-00B, VS-00D |
| Public web checkout becomes accidental primary product | P0 | `web_checkout_sales` is deferred until after WhatsApp-first launch stability. | VS-00D |
| Plaintext delivery or QR tokens are stored | P0 | Customer-facing tokens must be hash-only at rest, expiring, and revocable. | VS-00B |
| Token-bearing URLs enter logs | P0 | Log redaction must cover customer links, provider URLs, access codes, and headers. | VS-00B |
| Late payment after hold expiry oversells | P0 | Re-reserve/consume only if inventory is available; otherwise manual review. | VS-00A, VS-00C |
| Manual review becomes generic status mutation | P0 | Manual review exits must use explicit transitions, audit reasons, and allowed targets. | VS-00A |

## Review Rule

Each later implementation slice must either close the relevant risk through
tests and implementation, or explicitly keep it open with a documented blocker.
