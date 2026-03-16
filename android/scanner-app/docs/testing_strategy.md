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
