# VS-06A Paystack Client Boundary

## Scope implemented

VS-06A adds a plain provider boundary under `FastCheck.Payments.Paystack`:

- `Config` for enabled-gated runtime config loading/validation.
- `Client` for low-level Req execution and normalized errors.
- `TransactionInitializer` for `POST /transaction/initialize`.
- `TransactionVerifier` for `GET /transaction/verify/:reference`.
- `WebhookVerifier` for raw-body HMAC SHA512 signature verification.

## Security and observability

- Uses `FastCheck.Observability.Redactor` and `FastCheck.Observability.Correlation`.
- Redacts secrets, authorization values, access codes, authorization URLs, and buyer PII.
- Keeps callback/webhook URLs as config-only values for future slices.

## Boundary confirmation

This slice does **not** add:

- Sales checkout integration.
- `PaymentAttempt` or `PaymentEvent` actions/persistence wiring.
- Paystack webhook controller/route.
- Paystack Oban workers.
- Order/checkout state transitions.
- Ticket issuance, WhatsApp runtime, scanner/mobile changes, or inventory mutation.

## Runtime behavior

- `PAYSTACK_ENABLED=false` keeps provider boundary dormant and boot-safe.
- Production fail-fast applies only when `PAYSTACK_ENABLED=true` and required Paystack config is missing.
- Provider calls fail safely when required config is missing.
