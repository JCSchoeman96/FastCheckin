# Sales Channel Authority Model

## Authority Rule

All channels use the same Sales core:

- Redis `ReservationLedger` for inventory.
- Paystack server-side verification for payment acceptance.
- `FastCheck.Tickets.Issuer` for idempotent ticket issuance.
- `DeliveryAttempt` for delivery audit.
- `StateTransition` for state-change audit.
- Existing FastCheck attendee/scanner path for scanner validity.

## Channel Boundaries

| Channel | Authority boundary |
|---|---|
| WhatsApp | Interface only; calls approved Sales/Checkout services. |
| Internal pilot | Testing/controlled bridge only; calls approved Sales core. |
| Admin-assisted sales | Controlled secondary interface; not a bypass path. |
| Future web checkout | Secondary interface; not primary production direction. |

## Forbidden

- Channel-specific payment authority.
- Channel-specific inventory mutation.
- Direct ticket issuance from webhook/controller/channel code.
- Delivery history stored only in channel state.
- Scanner validity controlled by channel state.
- Role-only admin/operator access without event scope.
