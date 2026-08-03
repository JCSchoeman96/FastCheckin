# Android Repository-Backed Session Gate Design

**Beads issue:** `FastCheckin-er0y`

**Base commit:** `39aeaf6ad1063b4f97e6f98c26dd0333e4b7f16f`

## Problem

Manual Event A to Event B acceptance exposed a split-brain Android state. After Event A logout, the authenticated shell could reappear with Event A display metadata even though the authoritative encrypted context had already been cleared. Attendee sync then correctly reported that no active session existed.

The cause is a UI authority violation:

1. `AuthViewModel` stores a `ScannerSession` in persistent `AuthUiState`.
2. Editing login fields emits copies of that state while retaining the old session.
3. `MainActivity` treats every such emission as login success and forwards the retained session.
4. `SessionGateViewModel.onLoginSucceeded(session)` directly publishes an authenticated route without consulting `SessionRepository.currentSession()`.

This permits display state to authorize navigation after the secure context has changed.

## Authority invariant

> The authenticated shell may only be entered from a session freshly resolved through `SessionRepository.currentSession()`. No Activity, composable, auth form, or caller-provided `ScannerSession` may authorize navigation.

The repository-backed session returned by `currentSession()` is the only input allowed to produce `AppSessionRoute.Authenticated`. DataStore metadata, auth-form state, cached event labels, and one-shot UI effects are non-authoritative.

## Scope

This change is limited to session routing and authentication presentation integration:

- remove session authority from `AuthUiState`;
- emit a payload-free login completion effect;
- reload the authoritative repository session during gate initialization and after login;
- add a synchronous `LoggingOut` route;
- prevent stale asynchronous route completions;
- gate login, sync, flush, camera, and event actions on the session route;
- add focused unit and instrumentation regressions.

The following remain separate:

- structured `401`, `403`, and `429` handling (`FastCheckin-qgq4`);
- parked-scan logout dialog redesign (`FastCheckin-cnf5`);
- backend rate-limit changes;
- Room schema, migration, retention, or bucket changes;
- credential storage or multiple JWTs.

## Authentication presentation

`AuthUiState` contains presentation data only:

- event ID input;
- credential input;
- submission state;
- sanitized error text;

It must not import or contain `ScannerSession`, authenticated event identity, session generation, or bearer tokens.

`AuthViewModel` exposes a non-replaying one-shot effect stream:

```kotlin
sealed interface AuthEffect {
    data object LoginCommitted : AuthEffect
}
```

After `SessionRepository.login()` returns successfully, the ViewModel clears the credential, ends submission state, and sends exactly one `LoginCommitted`. The effect carries no event or session payload. A buffered `Channel` exposed with `receiveAsFlow()` prevents replay while allowing a temporarily stopped Activity collector to receive the pending completion. No success message is retained; the authoritative shell transition communicates success.

Activity recreation and process recovery do not depend on an `onResume()` authentication path. A temporarily stopped Activity retains the buffered effect, ViewModels normally survive configuration recreation, and a process-created `SessionGateViewModel` restores from the repository during initialization. `MainActivity.onResume()` must not independently reload or authenticate navigation.

`AuthViewModel.resetAfterLogout()` clears credential, event ID, submission, and error presentation. A failed login emits no completion effect and cannot affect the session route.

## Session gate state machine

`AppSessionRoute` gains `LoggingOut`:

```text
RestoringSession -> LoggedOut | Authenticated
Authenticated -> LoggingOut -> LoggedOut
LoggedOut -> RestoringSession -> LoggedOut | Authenticated
```

`SessionGateViewModel` removes every method accepting `ScannerSession`. Its public reload and login-commit entry points are payload-free:

```kotlin
fun reloadAuthoritativeSession()
fun onLoginCommitted()
```

`reloadAuthoritativeSession()` is the repository-only restoration operation and respects unresolved logout-recovery suppression. `onLoginCommitted()` is invoked only for the payload-free effect; it deliberately clears that suppression and then performs the same authoritative reload.

Reload behavior:

1. Ignore reload requests while `LoggingOut`.
2. Increment and capture the request revision synchronously.
3. Publish `RestoringSession` synchronously, hiding any previous shell and disabling login before launching suspend work.
4. Call `SessionRepository.currentSession()`.
5. Resolve expiry with `AppSessionRouteResolver`.
6. If expired, invoke `SessionRepository.onAuthExpired()` and remain logged out.
7. Publish `Authenticated(session)` only from the repository result and only if the revision is still current.
8. On repository failure, fail closed to `LoggedOut` and expose sanitized recovery text.

Initialization uses this reload without overriding unresolved logout recovery. The payload-free `LoginCommitted` path deliberately clears logout-recovery suppression and starts a fresh authoritative reload. No lifecycle-resume callback invokes it.

Logout behavior:

1. Publish `LoggingOut` synchronously before launching suspend work.
2. This immediately hides the shell, stops scanning/bootstrap activity, and disables login.
3. Call `SessionRepository.logout()`.
4. Publish `LoggedOut` only after logout completes.
5. If logout fails, make a best-effort `SessionRepository.onAuthExpired()` call, then read `currentSession()` for reconciliation.
6. Keep the shell hidden regardless of the reconciliation result and expose: `Logout could not be completed safely. Try again before leaving the device unattended.`
7. Mark logout recovery unresolved. Automatic restoration remains suppressed until an explicitly retried logout succeeds or a new successful payload-free `LoginCommitted` transition deliberately replaces the old context.

No UI mutex is added. The existing repository transition coordinator remains responsible for cross-store serialization. The ViewModel uses a monotonically increasing request revision solely to prevent an older reload result from publishing after a newer route transition. A reload requested during `LoggingOut` is ignored.

## MainActivity integration

`MainActivity` stops observing a session field in auth state. It separately collects `AuthViewModel.effects`; `LoginCommitted` calls the payload-free `sessionGateViewModel.onLoginCommitted()`, which then performs repository restoration.

The Activity treats only `AppSessionRoute.Authenticated` as operationally active:

- `RestoringSession`, `LoggingOut`, and `LoggedOut` hide the authenticated shell;
- scanner binding is stopped and scan-destination sync activity is deactivated;
- login submission is enabled only for `LoggedOut` while `AuthViewModel` is not submitting;
- Event actions, manual attendee sync, and manual queue flush return without executing unless the current route is `Authenticated`;
- camera activation continues to use the route-derived authenticated flag.

When `LoggingOut` first appears, auth presentation is reset. A session-gate recovery message is copied into the login presentation only after the shell is hidden.

## Failure and stale-completion policy

- A failed Event B login emits no effect, so the route remains logged out.
- A successful Event B login only requests a repository reload; Event B appears after the committed secure context is restored.
- An older repository reload cannot overwrite a later logout because its request revision is stale.
- Reload synchronously replaces any old shell with `RestoringSession`; login is disabled until repository resolution finishes.
- Lifecycle resume does not initiate repository restoration.
- A logout failure remains fail-closed, suppresses automatic restoration, and cannot resurrect Event A from auth-form state.
- A later successful payload-free `LoginCommitted` explicitly clears recovery suppression and can render a newly committed Event B after repository reload.
- Sync repositories retain their existing secure-context checks as defense in depth, but the UI no longer exposes actions without an authenticated route.

## Tests

### Unit tests

`AuthViewModelTest` verifies:

- successful login emits exactly one payload-free `LoginCommitted`;
- state contains no session authority;
- input edits cannot re-emit an old session;
- failed login emits no effect;
- reset clears credentials and stale presentation.

`SessionGateViewModelTest` verifies:

- repository Event B reload produces Event B;
- repository `null` produces `LoggedOut`;
- expiry invokes authoritative cleanup and remains logged out;
- logout publishes `LoggingOut` before a delayed repository logout finishes;
- reload is ignored during logout;
- reload synchronously hides the old shell with `RestoringSession` and disables login;
- a scripted stale reload captures Event A before waiting, returns it after logout, and cannot overwrite the newer route transition;
- logout failure remains logged out, exposes recovery text, and suppresses later automatic restoration;
- a later successful Event B `LoginCommitted` clears suppression and renders only repository-restored Event B.

### Instrumentation

A focused `MainActivitySessionAuthorityFlowTest` uses the test repository to exercise:

```text
Event A authenticated
-> unresolved Event A count visible
-> logout confirmed
-> Event B fields edited
-> Event B login fails or succeeds
```

It asserts that Event A disappears synchronously, login is disabled during delayed logout, field edits cannot reopen Event A, failed login stays logged out, operational actions do not execute without an authenticated route, and successful Event B rendering occurs only after repository reload.

Existing camera and screenshot instrumentation helpers must authenticate by seeding `TestSessionRepository` and triggering the same payload-free repository reload used by production; they may not recreate a caller-authoritative shortcut. The logout regression should operate the real overflow and confirmation UI. If an internal test seam proves unavoidable, it must be `internal`, annotated `@VisibleForTesting`, accept no session object, and invoke the exact production logout path.

## Evidence preservation and connected testing

The attached phone currently contains three queued Event A rows that are reproduction evidence. `connectedDebugAndroidTest` must not run against that phone because instrumentation installation or cleanup can remove debug-app data.

Connected verification must use another clean device, emulator, or clean Android profile. The evidence-bearing phone remains untouched until the focused fix has passed automated verification and manual acceptance is deliberately resumed.

## Acceptance criteria

- `AuthUiState` cannot carry session authority.
- No public session-gate API accepts `ScannerSession`.
- The shell is visible only for a repository-restored valid session.
- Logout hides the shell synchronously and prevents concurrent login.
- Failed Event B login cannot redisplay Event A.
- Successful Event B login renders only after authoritative reload.
- Sync and operational actions cannot execute while logged out or logging out.
- Delayed older completions cannot overwrite newer route state.
- Event A's queued rows remain unchanged.
