# Meta WhatsApp Security Policy

## Requirements

- Verify Meta webhook signatures/challenges as required by provider contract.
- Dedupe inbound and outbound message ids.
- Treat `phone_e164`, `wa_id`, message content, and conversation `state_data` as
  PII/sensitive provider data.
- Keep 24-hour customer-service window handling explicit.
- Use approved template fallback when required.
- Restrict operator/human handoff data by event permission.
- Avoid direct PII in `session_key` and `rate_limit_key` values where practical.

## Authority Rule

WhatsApp is an interface layer. It must not own:

- payment authority;
- inventory authority;
- ticket issuance;
- delivery audit;
- scanner validity.

WhatsApp state must call approved Sales/Checkout services. Payment-pending
messages must not contradict durable payment state.

## Future Tests

- Duplicate inbound messages are deduped.
- Message content is not logged in plaintext.
- WhatsApp flow cannot bypass `ReservationLedger`.
- WhatsApp flow cannot mark payment verified from message state.
