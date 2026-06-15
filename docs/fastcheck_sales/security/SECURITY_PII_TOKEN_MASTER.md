# Security, PII, and Token Master

## Default Rule

Every security policy applies to all Sales channels unless the policy explicitly
says otherwise:

- WhatsApp sales.
- Admin-assisted sales.
- Internal pilot sales.
- Future web checkout sales.

## Security Principles

- Interfaces do not own security boundaries.
- Actor role alone is insufficient for access; event scope is required.
- Customer-facing tokens are never stored in plaintext.
- PII and provider secrets are never logged in plaintext.
- Raw provider payloads are restricted to system and explicit admin support
  contexts.
- Paystack webhook payload alone is not payment authority.
- WhatsApp identifiers and message content are PII/sensitive provider data.

## Actor Types

| Actor | Access posture |
|---|---|
| `system` | May process sensitive fields required for workflows; must redact logs. |
| `admin` | May access event-scoped support detail and restricted raw payload views. |
| `operator` | May access event-scoped support summaries; masked by default. |
| `customer_session` | May access only controlled token/session/order data. |

## Event-Scoped First

First release uses `event_scoped_first`. Sales records are scoped by FastCheck
event where event-owned or event-derived. `organization_id` is deferred until a
later approved tenant-isolation slice introduces a real organization model,
membership model, policy model, indexes, and cross-tenant denial tests.
