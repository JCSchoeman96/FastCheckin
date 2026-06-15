# Primary Channel and Multi-Channel Strategy

## Decision

FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:

```text
whatsapp_first_paid_core
```

Payment provider:

```text
Paystack
```

Ticket/scanner authority:

```text
FastCheck backend and existing scanner-compatible Attendee path
```

## Channel Roles

| Channel | Role |
|---|---|
| WhatsApp | First production customer interface through Meta Cloud API. |
| Internal pilot | Controlled testing bridge before public traffic. |
| Admin-assisted sales | Controlled secondary path before launch. |
| Public web checkout | Deferred secondary channel after WhatsApp-first path is stable. |

## Strategic Rule

Channels are interfaces. They do not own durable Sales state, inventory
authority, payment authority, ticket issuance, delivery audit, or scanner
validity.
