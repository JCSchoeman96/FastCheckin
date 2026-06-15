# Secret and Config Policy

## Covered Secrets

- Paystack secret keys.
- Paystack public keys if used.
- Meta access tokens.
- Meta app secret.
- Webhook verification secrets.
- Phoenix `secret_key_base`.
- Signing salts/keys for tokens.
- Runtime environment variables.

## Rules

- Secrets must not be committed to the repo.
- Secrets must not be placed in planning docs.
- Runtime config must read secrets from environment or an accepted secret store.
- Tests must use fake or sandbox secrets only.
- Provider clients must avoid logging request headers or secrets.
- Sandbox and production provider config must remain separated.

## Future Tests

- Provider clients do not log headers/secrets.
- Missing required runtime secret fails closed.
- Sandbox config cannot silently use production secrets in tests.
