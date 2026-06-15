# Raw Provider Payload Policy

## Purpose

Define storage, access, retention, and display rules for raw Paystack and
Meta/WhatsApp payloads.

## Access Rules

| Actor | Access |
|---|---|
| `system` | May process raw payloads for verification, dedupe, audit, and support workflows. |
| `admin` | May access raw payloads only in restricted event-scoped support/debug views. |
| `operator` | Denied by default. |
| `customer_session` | Denied. |

## Retention

Raw payloads may be retained for audit and dispute support for the minimum
period required by business, payment, and operational needs. The first
implementation must make retention configurable or documented, and must avoid
indefinite casual display.

## Provider Notes

- Paystack webhook raw payloads may contain customer/payment metadata.
- Meta webhook raw payloads may contain customer identifiers and message content.
- WhatsApp `state_data` may contain customer-entered data and is sensitive.

## Rules

- Raw payloads are redacted from logs.
- Raw payload display is restricted and event-scoped.
- Operator default views show summarized safe fields only.
- Payload minimization is preferred when full raw payload retention is not
  required.
