# Launch Scope Test Requirements

## Future Tests Required By Selected Scope

- Orders created from WhatsApp have `source_channel = whatsapp`.
- Orders created from admin-assisted flow have `source_channel = admin`.
- Orders created from internal pilot have `source_channel = test` or accepted
  pilot attribution.
- Future web checkout orders have `source_channel = web` only when that path is
  implemented later.
- All selected source channels use `ReservationLedger`.
- All selected source channels create `PaymentAttempt` through the approved
  Paystack path.
- All selected source channels require Paystack server-side verification before
  ticket issuance.
- All selected source channels issue tickets only through the approved issuer.
- All selected source channels record `StateTransition` audit.
- All ticket delivery/resend flows record `DeliveryAttempt`.
- Revocation is scanner-visible for tickets from every selected source channel.
- PII/log redaction applies to every selected source channel.
- Admin/operator list/read/manual-action tests deny cross-event records.

## VS-22 Impact

VS-22 must cover:

- WhatsApp-first paid core.
- Internal pilot bridge.
- Admin-assisted secondary path.
- Deferred web checkout remains out of first launch scope.
