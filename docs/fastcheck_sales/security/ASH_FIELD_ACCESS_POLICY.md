# Ash Field Access Policy

## Purpose

Define future Ash field-level access expectations before resources are
implemented.

## Actor Access Matrix

| Resource | Field | system | admin | operator | customer_session | Masking / restriction |
|---|---|---:|---:|---:|---:|---|
| Order | `buyer_name` | allow | allow event-scoped detail | masked list / support detail | own controlled flow only | Mask in lists. |
| Order | `buyer_phone` | allow | allow event-scoped detail | masked list / support detail | own controlled flow only | Example: `+2782******34`. |
| Order | `buyer_email` | allow | allow event-scoped detail | masked list / support detail | own controlled flow only | Example: `j***@example.com`. |
| Order | `public_reference` | allow | allow event-scoped | allow event-scoped | own controlled flow only | Customer-safe reference; not sequential id. |
| Order | `idempotency_key` | allow | restricted | deny | deny | Internal only by default. |
| PaymentAttempt | `provider_reference` | allow | restricted event-scoped | masked | deny | Show first6/last4 where practical. |
| PaymentAttempt | `authorization_url` | allow send-only | restricted | deny | intended channel only | Never log. |
| PaymentAttempt | `access_code` | allow | restricted debug only | deny | deny | Never log. |
| PaymentAttempt | `raw_initialize_response` | allow | restricted | deny | deny | Raw payload restricted. |
| PaymentAttempt | `raw_verify_response` | allow | restricted | deny | deny | Raw payload restricted. |
| PaymentEvent | `raw_payload` | allow | restricted | deny | deny | Restricted support/debug view only. |
| TicketIssue | `ticket_code` | allow | event-scoped detail | masked/limited | own controlled flow only | Avoid broad list exposure. |
| TicketIssue | `delivery_token_hash` | allow | restricted | deny | deny | Never expose hash in UI. |
| TicketIssue | `qr_token_hash` | allow | restricted | deny | deny | Never expose hash in UI. |
| DeliveryAttempt | `recipient` | allow | event-scoped detail | masked summary | own controlled flow only | Treat as PII. |
| Conversation | `phone_e164` | allow | event-scoped detail | masked summary | own controlled flow only | Treat as PII. |
| Conversation | `wa_id` | allow | restricted | deny by default | own controlled flow only | Provider identity. |
| Conversation | `state_data` | allow | restricted | deny by default | own controlled flow only | May contain PII. |
| StateTransition | `reason` | allow | allow event-scoped | own/manual summaries only | deny | Required for manual actions. |
| StateTransition | `metadata` | allow | restricted | deny by default | deny | May contain sensitive refs. |

## Rules

- Admin/operator reads must be event-scoped.
- `customer_session` must never perform broad Ash reads.
- Operator access is narrower than admin access.
- Raw payload access requires restricted admin/system path.
- Future policy tests must prove cross-event denial.
