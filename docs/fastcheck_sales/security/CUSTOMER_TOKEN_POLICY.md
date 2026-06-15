# Customer Token Policy

## Purpose

Define customer-facing delivery and QR token requirements.

## Rules

- Plaintext delivery tokens must never be stored.
- Plaintext QR tokens must never be stored.
- Only token hashes may be stored.
- Token-bearing URLs must not be logged.
- Delivery tokens must expire or be revocable.
- Revoked/refunded/cancelled tickets must invalidate or block customer ticket
  access.
- Secure ticket pages must never expose raw internal ids or provider internals.
- Token scope must be limited to the intended ticket/order/customer flow.

## Failure Behavior

| Case | Customer-facing behavior |
|---|---|
| Invalid token | Show generic invalid/expired link message; do not reveal whether ticket exists. |
| Expired token | Show safe expired-link message and support/resend path if allowed. |
| Revoked ticket | Show contact/support message; do not show scannable QR. |
| Payment pending | Do not say payment does not exist if durable payment state exists. |

## Future Tests

- No plaintext token persistence.
- Token-bearing URL is redacted from logs.
- Expired token does not reveal whether ticket exists.
- Revoked token does not render a QR.
