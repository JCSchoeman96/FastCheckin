# Paystack Security Policy

## Requirements

- Verify webhook signatures before processing.
- Store and dedupe events before worker processing.
- Run server-side transaction verification before accepted payment state.
- Check amount, currency, provider status, provider reference, and event/order
  ownership.
- Treat `authorization_url` as sensitive.
- Treat `access_code` as sensitive and never operator/customer visible.
- Separate sandbox and production config.

## Payment Authority Rule

Paystack webhook payload alone is not payment authority. Only server-side
verification can move `PaymentAttempt` to `verified_success` or Order to
`paid_verified`.

## Logging Rules

- Do not log `authorization_url`.
- Do not log `access_code`.
- Do not log raw initialize or verify responses.
- Do not log provider request headers or secrets.
- Use masked provider references and correlation ids.

## Future Tests

- Invalid signature does not enqueue verification.
- Amount mismatch moves to manual review.
- Currency mismatch moves to manual review.
- Webhook-only success cannot mark payment verified.
- `access_code` never appears in captured logs.
