# Android Repository-Backed Session Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure the Android authenticated shell can only be entered from a valid session freshly restored through `SessionRepository.currentSession()`.

**Architecture:** `AuthViewModel` becomes presentation-only and emits a payload-free, non-replaying login effect. `SessionGateViewModel` owns route transitions, reloads only from the repository, hides the shell synchronously with `LoggingOut`, and rejects stale asynchronous results with a request revision. `MainActivity` consumes effects and gates every operational action on `AppSessionRoute.Authenticated`.

**Tech Stack:** Kotlin, Android ViewModel, Coroutines `StateFlow`/`Channel`, Hilt, Robolectric, Android instrumentation, Truth.

---

### Task 1: Remove session authority from the auth form

**Files:**
- Create: `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/auth/AuthEffect.kt`
- Modify: `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/auth/AuthUiState.kt`
- Modify: `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/auth/AuthViewModel.kt`
- Test: `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/auth/AuthViewModelTest.kt`

- [ ] **Step 1: Replace the existing successful-login test with failing presentation/effect tests**

Add tests that collect `effects` with `backgroundScope` and assert:

```kotlin
@Test
fun successfulLoginEmitsOnePayloadFreeCommittedEffect() = runTest(dispatcher) {
    val repository = RecordingSessionRepository(Result.success(testSession(eventId = 18L)))
    val viewModel = AuthViewModel(repository)
    val effects = mutableListOf<AuthEffect>()
    backgroundScope.launch(dispatcher) { viewModel.effects.toList(effects) }

    viewModel.updateEventId("18")
    viewModel.updateCredential("test-credential")
    viewModel.login()
    advanceUntilIdle()

    assertThat(effects).containsExactly(AuthEffect.LoginCommitted)
    assertThat(viewModel.uiState.value.credentialInput).isEmpty()
    assertThat(viewModel.uiState.value.isSubmitting).isFalse()
}

@Test
fun failedLoginEmitsNoCommittedEffect() = runTest(dispatcher) {
    val repository = RecordingSessionRepository(Result.failure(IllegalStateException("Login failed.")))
    val viewModel = AuthViewModel(repository)
    val effects = mutableListOf<AuthEffect>()
    backgroundScope.launch(dispatcher) { viewModel.effects.toList(effects) }

    viewModel.updateEventId("19")
    viewModel.updateCredential("test-credential")
    viewModel.login()
    advanceUntilIdle()

    assertThat(effects).isEmpty()
    assertThat(viewModel.uiState.value.errorMessage).isEqualTo("Login failed.")
}

@Test
fun resetAfterLogoutClearsCredentialsAndPresentation() {
    val viewModel = AuthViewModel(RecordingSessionRepository(Result.success(testSession(18L))))
    viewModel.updateEventId("19")
    viewModel.updateCredential("test-credential")
    viewModel.setExternalError("Recovery message")

    viewModel.resetAfterLogout()

    assertThat(viewModel.uiState.value).isEqualTo(AuthUiState())
}
```

Also add a Java-reflection assertion over `AuthUiState::class.java.declaredFields` that no field type is `ScannerSession`, `AuthenticatedEventIdentity`, or `AuthenticatedEventContext`; this avoids adding Kotlin reflection.

- [ ] **Step 2: Run the focused auth tests and verify RED**

Run:

```bash
cd android/scanner-app
./gradlew testDebugUnitTest --tests '*AuthViewModelTest'
```

Expected: compilation/test failure because `AuthEffect`, `effects`, and `resetAfterLogout()` do not exist and `authenticatedSession` still exists.

- [ ] **Step 3: Implement the payload-free effect and presentation-only state**

Create:

```kotlin
sealed interface AuthEffect {
    data object LoginCommitted : AuthEffect
}
```

Make `AuthUiState` presentation-only:

```kotlin
data class AuthUiState(
    val eventIdInput: String = "",
    val credentialInput: String = "",
    val isSubmitting: Boolean = false,
    val errorMessage: String? = null
)
```

In `AuthViewModel`, expose a buffered, non-replaying channel:

```kotlin
private val effectChannel = Channel<AuthEffect>(capacity = Channel.BUFFERED)
val effects: Flow<AuthEffect> = effectChannel.receiveAsFlow()
```

On successful `sessionRepository.login(...)`, do not store the returned session. Set `isSubmitting = false`, clear the credential and error state, and call:

```kotlin
effectChannel.send(AuthEffect.LoginCommitted)
```

On failure, retain the existing generic error behavior for this bug and emit no effect. Add:

```kotlin
fun resetAfterLogout() {
    _uiState.value = AuthUiState()
}
```

- [ ] **Step 4: Run the focused auth tests and verify GREEN**

Run the focused command from Step 2. Expected: all `AuthViewModelTest` tests pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/auth/AuthEffect.kt \
  android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/auth/AuthUiState.kt \
  android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/auth/AuthViewModel.kt \
  android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/auth/AuthViewModelTest.kt
git commit -m "Fix auth form session authority"
```

### Task 2: Make the session gate repository-authoritative

**Files:**
- Modify: `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/AppSessionRoute.kt`
- Modify: `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModel.kt`
- Test: `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModelTest.kt`

- [ ] **Step 1: Add delayed-repository failing tests**

Extend the fake repository with scripted `currentSession()` calls and `CompletableDeferred<Unit>` gates for repository reads and logout. A delayed scripted read must capture its return value before waiting so the test can return a genuinely stale Event A after mutable repository state changes. Add tests for:

```kotlin
@Test
fun reloadUsesRepositoryEventInsteadOfCallerState() = runTest {
    val eventB = testSession(eventId = 19L, expiresAtEpochMillis = clock.millis() + 60_000)
    val repository = FakeSessionRepository(currentSession = eventB)
    val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())

    advanceUntilIdle()

    assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(eventB))
}

@Test
fun reloadSynchronouslyHidesShellWhileRepositoryReadIsDelayed() = runTest {
    val eventA = testSession(eventId = 18L, expiresAtEpochMillis = clock.millis() + 60_000)
    val repository = FakeSessionRepository(currentSession = eventA)
    val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
    advanceUntilIdle()
    val reloadRelease = repository.scriptCurrentSession(
        result = eventA,
        suspendAfterCapture = true
    )

    viewModel.reloadAuthoritativeSession()

    assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.RestoringSession)
    assertThat(viewModel.canSubmitLogin.value).isFalse()
    reloadRelease.complete(Unit)
    advanceUntilIdle()
    assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(eventA))
}

@Test
fun logoutHidesAuthenticatedRouteBeforeRepositoryFinishes() = runTest {
    val logoutRelease = CompletableDeferred<Unit>()
    val repository = FakeSessionRepository(testSession(), logoutRelease = logoutRelease)
    val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
    advanceUntilIdle()

    viewModel.logout()

    assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggingOut)
    logoutRelease.complete(Unit)
    advanceUntilIdle()
    assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
}

@Test
fun staleReloadCannotOverwriteNewerLogout() = runTest {
    val eventA = testSession(eventId = 18L)
    val repository = FakeSessionRepository(eventA)
    val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
    advanceUntilIdle()
    val reloadRelease = repository.scriptCurrentSession(
        result = eventA,
        suspendAfterCapture = true
    )

    viewModel.reloadAuthoritativeSession()
    repository.awaitScriptedCurrentSessionCaptured()
    viewModel.logout()
    advanceUntilIdle()
    reloadRelease.complete(Unit)
    advanceUntilIdle()

    assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
}

@Test
fun logoutFailureRemainsLoggedOutSuppressesAutomaticRestoreAndSurfacesRecovery() = runTest {
    val repository = FakeSessionRepository(testSession(), logoutFailure = IOException("disk"))
    val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
    advanceUntilIdle()

    viewModel.logout()
    advanceUntilIdle()

    assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
    assertThat(viewModel.recoveryMessage.value)
        .isEqualTo(
            "Logout could not be completed safely. " +
                "Try again before leaving the device unattended."
        )
    assertThat(repository.authExpiredCalls).isEqualTo(1)

    viewModel.reloadAuthoritativeSession()
    advanceUntilIdle()

    assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
}
```

Also test that a later successful payload-free `LoginCommitted` clears unresolved logout suppression, reloads the newly committed Event B from the repository, and never redisplays Event A. The fake's scripted stale-read path captures the configured result before signaling `awaitScriptedCurrentSessionCaptured()` and before waiting on its release.

Delete the test that calls `onLoginSucceeded(session)` and assert with `SessionGateViewModel::class.java.methods` that no public method has a `ScannerSession` parameter.

- [ ] **Step 2: Run focused session-gate tests and verify RED**

```bash
cd android/scanner-app
./gradlew testDebugUnitTest --tests '*SessionGateViewModelTest'
```

Expected: failures because `LoggingOut`, `recoveryMessage`, delayed transition protection, and the payload-free reload contract do not exist.

- [ ] **Step 3: Implement LoggingOut and revision-guarded repository reloads**

Add:

```kotlin
data object LoggingOut : AppSessionRoute
```

In `SessionGateViewModel`, remove `onLoginSucceeded(session)`. Keep a payload-free `reloadAuthoritativeSession()` repository-restoration entry point and add a payload-free `onLoginCommitted()` entry point. Initialization calls `reloadAuthoritativeSession()`. The login-commit entry point is the only path that clears logout-recovery suppression before invoking the same reload. Maintain:

```kotlin
private var requestRevision: Long = 0L
private var logoutRecoveryRequired: Boolean = false
private val _recoveryMessage = MutableStateFlow<String?>(null)
val recoveryMessage: StateFlow<String?> = _recoveryMessage.asStateFlow()
```

Every reload returns immediately while `LoggingOut`. It also returns without reading the repository while `logoutRecoveryRequired` is true. Otherwise it synchronously captures `val revision = ++requestRevision`, publishes `RestoringSession`, and only then launches the repository read. After each suspend boundary it publishes only when `revision == requestRevision`. The payload-free `onLoginCommitted()` entry point clears `logoutRecoveryRequired` before beginning its reload because a successful repository login deliberately replaces the unresolved context. No `onResume()` callback calls either API.

Add `SessionRepository.expireSession(eventId, sessionGeneration)` for restoration expiry. `CurrentPhoenixSessionRepository` maps it to `AuthenticatedSessionTransitionCoordinator.expire(AuthenticatedEventIdentity(eventId, sessionGeneration))`. Before requesting cleanup, the gate confirms the reload revision is still current; after cleanup suspends, it rechecks the revision before publishing. The no-argument `onAuthExpired()` remains only for genuinely current-session failure paths such as logout recovery.

Add a regression whose delayed repository read captures expired Event A before waiting. Commit and authenticate Event B through a newer reload, then release the stale Event A read. Assert that Event B and its generation remain authoritative, the route remains Event B, and current-session expiry is never invoked for stale Event A.

Implement logout as:

```kotlin
fun logout() {
    if (_route.value == AppSessionRoute.LoggingOut) return
    val revision = ++requestRevision
    _route.value = AppSessionRoute.LoggingOut
    _recoveryMessage.value = null
    viewModelScope.launch {
        runCatching { sessionRepository.logout() }
            .onSuccess {
                if (revision == requestRevision) {
                    logoutRecoveryRequired = false
                    _route.value = AppSessionRoute.LoggedOut
                }
            }
            .onFailure {
                runCatching { sessionRepository.onAuthExpired() }
                runCatching { sessionRepository.currentSession() }
                if (revision == requestRevision) {
                    logoutRecoveryRequired = true
                    _route.value = AppSessionRoute.LoggedOut
                    _recoveryMessage.value =
                        "Logout could not be completed safely. " +
                            "Try again before leaving the device unattended."
                }
            }
    }
}
```

Keep logout-failure cleanup through `onAuthExpired()`. Restoration expiry must use `expireSession(eventId, sessionGeneration)` and never `expireCurrent()`. Repository exceptions must publish `LoggedOut` plus a sanitized recovery message, never a cached authenticated route. The reconciliation read after logout failure is diagnostic only: its result must never make the shell visible. A later explicit logout retry can clear suppression only after it succeeds; a payload-free `LoginCommitted` can clear it before reloading the newly committed repository session.

- [ ] **Step 4: Run both focused test classes and verify GREEN**

```bash
./gradlew testDebugUnitTest \
  --tests '*AuthViewModelTest' \
  --tests '*SessionGateViewModelTest'
```

Expected: both focused test classes pass.

- [ ] **Step 5: Commit Task 2**

```bash
git add android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/AppSessionRoute.kt \
  android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModel.kt \
  android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModelTest.kt
git commit -m "Make session gate repository authoritative"
```

### Task 3: Gate MainActivity integration and operational actions

**Files:**
- Modify: `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- Create: `android/scanner-app/app/src/androidTest/java/za/co/voelgoed/fastcheck/app/MainActivitySessionAuthorityFlowTest.kt`
- Test support: `android/scanner-app/app/src/androidTest/java/za/co/voelgoed/fastcheck/di/TestSessionRepository.kt`

- [ ] **Step 1: Add a failing Activity regression with delayed logout**

Extend `TestSessionRepository` with resettable test controls: login result, login call count, `CompletableDeferred<Unit>?` logout release, a current session setter, and opt-in scripted `currentSession()` behavior that captures its result before any deferred wait. Keep defaults identical for unrelated instrumentation tests.

Create `MainActivitySessionAuthorityFlowTest` with Hilt. The primary test must:

```kotlin
@Test
fun logoutThenEditingNextLoginCannotRestorePreviousEvent() {
    val eventA = testSessionRepository.session(eventId = 18L, eventName = "Event A", authenticatedAtEpochMillis = now)
    testSessionRepository.setCurrentSession(eventA)
    testSessionRepository.delayNextLogout()
    val insertedQueueIds = runBlocking {
        List(3) { index ->
            scannerDao.insertQueuedScan(
                QueuedScanEntity(
                    eventId = 18L,
                    ticketCode = "TEST-${index + 1}",
                    idempotencyKey = "event-a-${index + 1}",
                    createdAt = now + index,
                    scannedAt = "2026-08-03T10:00:0${index}Z",
                    entranceName = "Test entrance",
                    operatorName = "Test operator"
                )
            )
        }
    }

    val scenario = ActivityScenario.launch(MainActivity::class.java)
    waitUntil { currentRoute(scenario) == AppSessionRoute.Authenticated(eventA) }

    openOverflowMenuAndConfirmLogoutWithComposeUi()
    waitUntil { currentRoute(scenario) == AppSessionRoute.LoggingOut }
    assertShellHidden(scenario)
    assertLoginDisabled(scenario)

    scenario.onActivity {
        it.findViewById<EditText>(R.id.event_id_input).setText("19")
        it.findViewById<EditText>(R.id.credential_input).setText("test-credential")
    }

    assertThat(currentRoute(scenario)).isEqualTo(AppSessionRoute.LoggingOut)
    testSessionRepository.completeLogout()
    waitUntil { currentRoute(scenario) == AppSessionRoute.LoggedOut }
    assertShellHidden(scenario)
    assertThat(runBlocking { scannerDao.countPendingScansForEvent(18L) }).isEqualTo(3)
    scenario.close()
    runBlocking { scannerDao.deleteQueuedScans(insertedQueueIds) }
}
```

Drive logout through the real overflow menu and confirmation action. Do not add a public production `confirmLogoutForTest()` shortcut. If UI automation proves an internal seam unavoidable, it must be `internal`, annotated `@VisibleForTesting`, accept no session object, and invoke the exact production logout path.

Inject the existing `ScannerDao` into the test. Wrap the Activity assertions in `try/finally`; the `finally` block closes the scenario and calls `scannerDao.deleteQueuedScans(insertedQueueIds)`, so only rows created by the test are removed. Add companion cases proving failed Event B login stays logged out, successful Event B login shows Event B only after `currentSession()` reload, and the Event screen—including its sync and flush actions—is absent while logged out, restoring, or logging out. Assert the test repository login call count does not change when the disabled login button is clicked during delayed logout.

- [ ] **Step 2: Compile instrumentation and verify RED**

```bash
cd android/scanner-app
./gradlew :app:compileDebugAndroidTestKotlin --no-daemon
```

Expected: compilation failure because the production route/effect integration and new test controls are absent.

- [ ] **Step 3: Replace caller-authoritative Activity wiring**

In `MainActivity`:

- remove the `uiState.authenticatedSession` observer block;
- collect `authViewModel.effects` and call the payload-free `onLoginCommitted()` for `LoginCommitted`;
- do not add an `onResume()` repository reload or any second lifecycle authentication path;
- update the login click listener to run only when `route.value == AppSessionRoute.LoggedOut`;
- enable the login button only when the route is `LoggedOut` and auth is not submitting;
- treat `RestoringSession`, `LoggingOut`, and `LoggedOut` as non-authenticated, hiding the shell and stopping scanner/sync activity;
- call `authViewModel.resetAfterLogout()` when `LoggingOut` begins;
- collect `recoveryMessage` into `authViewModel.setExternalError(...)`;
- guard `handleEventOperatorAction`, manual sync, and manual flush with an exact `Authenticated` route check.

Use a private helper so both route and auth-state collectors apply the same rule:

```kotlin
private fun updateLoginButtonEnabled() {
    binding.loginButton.isEnabled =
        sessionGateViewModel.route.value == AppSessionRoute.LoggedOut &&
            !authViewModel.uiState.value.isSubmitting
}
```

- [ ] **Step 4: Compile instrumentation and run focused unit tests**

```bash
./gradlew :app:compileDebugAndroidTestKotlin --no-daemon
./gradlew testDebugUnitTest \
  --tests '*AuthViewModelTest' \
  --tests '*SessionGateViewModelTest'
```

Expected: instrumentation compilation and focused unit tests pass.

- [ ] **Step 5: Commit Task 3**

```bash
git add android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt \
  android/scanner-app/app/src/androidTest/java/za/co/voelgoed/fastcheck/app/MainActivitySessionAuthorityFlowTest.kt \
  android/scanner-app/app/src/androidTest/java/za/co/voelgoed/fastcheck/di/TestSessionRepository.kt
git commit -m "Gate Android shell on authoritative session"
```

### Task 4: Migrate existing instrumentation away from caller sessions

**Files:**
- Modify: `android/scanner-app/app/src/androidTest/java/za/co/voelgoed/fastcheck/app/MainActivityCameraRecoveryFlowTest.kt`

- [ ] **Step 1: Update test authentication helpers without adding a shortcut**

Replace calls to `onLoginSucceeded(session)` by seeding the test repository and triggering the payload-free gate reload through the existing production entry point:

```kotlin
testSessionRepository.setCurrentSession(session)
scenario.onActivity { activity ->
    viewModel<SessionGateViewModel>(activity).reloadAuthoritativeSession()
}
```

Integration-mode tests continue to perform real login through `AuthViewModel`; they must not seed the fake repository.

- [ ] **Step 2: Compile all instrumentation sources**

```bash
cd android/scanner-app
./gradlew :app:compileDebugAndroidTestKotlin --no-daemon
```

Expected: compilation passes with no caller-authoritative session method remaining.

- [ ] **Step 3: Audit forbidden authority APIs**

```bash
rg "authenticatedSession|onLoginSucceeded" android/scanner-app/app/src
```

Expected: no production or test references. `ScannerSession` may remain only in `AppSessionRoute.Authenticated` and repository/domain contracts, never in `AuthUiState` or an input parameter of the gate.

- [ ] **Step 4: Commit Task 4**

```bash
git add android/scanner-app/app/src/androidTest/java/za/co/voelgoed/fastcheck/app/MainActivityCameraRecoveryFlowTest.kt
git commit -m "Update session authority instrumentation"
```

### Task 5: Full verification without touching evidence data

**Files:**
- No production changes.

- [ ] **Step 1: Run focused and complete local Android verification**

```bash
cd android/scanner-app
./gradlew testDebugUnitTest \
  --tests '*AuthViewModelTest' \
  --tests '*SessionGateViewModelTest'
./gradlew :app:compileDebugAndroidTestKotlin --no-daemon
./gradlew testDebugUnitTest assembleDebug lintDebug --no-daemon
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 2: Run connected tests on a clean target only**

Do not use `R5GL30KWZ7D`; it contains the three queued reproduction rows. After attaching a clean emulator, device, or Android profile, set `CLEAN_ANDROID_SERIAL` to its actual serial and run:

```bash
ANDROID_SERIAL="$CLEAN_ANDROID_SERIAL" ./gradlew connectedDebugAndroidTest --no-daemon
```

Expected: the full connected suite executes more than zero tests with zero failures, including `MainActivitySessionAuthorityFlowTest`.

- [ ] **Step 3: Confirm the evidence phone was not mutated**

Reconnect read-only and verify the debug package still exists. Resume manual acceptance only after review of the automated fix; confirm Event A still shows its three queued rows before attempting Event B.

- [ ] **Step 4: Review scope and diff**

```bash
rg "HttpException|Retry-After|login_limit|throttle_login" \
  android/scanner-app/app/src lib test
git diff --check
git diff --stat 39aeaf6ad1063b4f97e6f98c26dd0333e4b7f16f...HEAD
```

Expected: no backend rate-limit, structured login error, Room schema, bucket lifecycle, or logout-dialog redesign files appear.

- [ ] **Step 5: Push a dedicated PR**

Push `fix/session-route-authority` and open an unmerged PR referencing `FastCheckin-er0y`. Include focused red/green evidence, full verification, clean-device connected results, and the explicit statement that the evidence phone was not used for instrumentation.
