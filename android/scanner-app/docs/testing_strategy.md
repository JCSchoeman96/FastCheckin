# Testing Strategy

## Unit Tests

Required unit coverage:

- DTO to Room entity mapping
- Room entity to domain model mapping
- Room DAO behavior
- queued scan idempotency handling
- worker flush orchestration
- analyzer boundary proving no direct network path
- runtime `IN` direction exposure

### B1 — truthful queue/flush UI projection (post-B1)

Required focused coverage for the truth-modeling slice:

- **Queued locally without flush result**: queue depth shown; server result hidden/neutral.
- **Uploading while queue still exists**: upload state shows Uploading; queue depth remains repository-derived.
- **Retry pending**: retry metadata present; upload state shows Retry pending with attempt.
- **Auth expired**: reflected in upload state.
- **Server result shown only from persisted/classified outcomes** (no message parsing for terminal error precision).

## Hilt Tests

Hilt runtime wiring requires Hilt test setup in the same scaffold pass.

Instrumentation tests should use:

- `HiltTestRunner`
- `@HiltAndroidTest`
- `@TestInstallIn` or `@UninstallModules` to replace production bindings

Replacement targets to document and support:

- repositories
- Room-backed collaborators when needed
- worker-facing use cases
- scanner-boundary collaborators

## Worker Tests

Worker tests should verify:

- batch chunking at `50`
- retry on retryable failures
- auth-expiry stop behavior
- no direct dependency on scanner UI code

## Contract Discipline

No Android test should reference future scanner routes as active dependencies.

Reason-code coverage must also prove:

- `status` and row presence still decide terminal vs retryable behavior
- `reason_code` is optional and additive only
- proven refinements are only `replay_duplicate`, `business_duplicate`, and
  `payment_invalid`
- `replay_duplicate` is trusted only for final replay duplicates
- `message` is not contract truth
- missing result rows after HTTP 200 remain retryable
