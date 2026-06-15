# PII Data Classification

## Classification Matrix

| Data | Classification | Rules |
|---|---|---|
| `buyer_name` | PII | Mask in list views where practical; never log broadly. |
| `buyer_phone` | PII | Normalize to E.164 where possible; mask in lists. |
| `buyer_email` | PII | Mask in lists; never use as broad lookup without event scope. |
| `phone_e164` | PII | WhatsApp identity; no plaintext logs. |
| `wa_id` | PII/provider identity | Sensitive; restricted support display. |
| `recipient` | PII | Delivery target; mask by default. |
| `raw_payload` | sensitive provider payload | Restricted to system and explicit admin support views. |
| `raw_initialize_response` | sensitive provider payload | Restricted; may contain payment/customer data. |
| `raw_verify_response` | sensitive provider payload | Restricted; may contain payment/customer data. |
| `authorization_url` | sensitive payment URL | Never log; customer-visible only through intended channel. |
| `access_code` | sensitive provider value | Never log; hidden from operator/customer. |
| `delivery_token_hash` | sensitive token hash | Store hash only; do not expose in UI. |
| `qr_token_hash` | sensitive token hash | Store hash only; do not expose in UI. |
| `ticket_code` | sensitive customer ticket identifier | Avoid broad list exposure. |
| `provider_reference` | sensitive payment reference | Mask in logs/support lists. |
| `idempotency_key` | internal safety key | Do not expose to customer/operator by default. |
| `session_key` | sensitive session key | Do not log; do not place PII in key names. |
| `rate_limit_key` | sensitive operational key | Avoid direct PII in key names. |

## Required Rules

- Do not use floats for money.
- Do not store plaintext customer-facing tokens.
- Do not use sequential DB ids as customer-facing references.
- Do not place phone numbers, emails, access codes, authorization URLs, or
  plaintext tokens in logs.
- Do not put PII directly into Redis key names where avoidable.
