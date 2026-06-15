# Log Redaction Policy

## Must Never Be Logged In Plaintext

- `buyer_name`
- `buyer_phone`
- `buyer_email`
- `phone_e164`
- `wa_id`
- `recipient`
- `access_code`
- `authorization_url`
- `raw_initialize_response`
- `raw_verify_response`
- `raw_payload`
- plaintext delivery token
- plaintext QR token
- provider payloads containing customer data
- Paystack signature/header values when sensitive
- Meta webhook signature/header values when sensitive
- `session_key`
- `rate_limit_key`
- `idempotency_key` where unnecessary

## Allowed Log Metadata

- `public_reference`
- internal resource id in protected internal logs
- status/state
- provider name
- event type
- `amount_cents`
- currency
- `correlation_id`
- `request_id`
- worker job id
- masked `provider_reference`

## Rules

- Debug logs in development follow the same redaction expectations for secrets
  and tokens.
- Token-bearing URLs are redacted as full values, not partially masked.
- Raw provider payloads are never logged as structured metadata.
- Provider client logs must avoid request headers and secrets.
