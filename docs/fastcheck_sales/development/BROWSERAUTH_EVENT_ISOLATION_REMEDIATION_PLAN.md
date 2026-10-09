# BrowserAuth Event-Isolation Remediation Plan

| Field | Value |
|-------|-------|
| **Plan ID** | BROWSERAUTH-EVENT-ISOLATION-REMEDIATION |
| **Plan version** | 1.3 |
| **Status** | FROZEN |
| **Scope** | Preserve BrowserAuth Event isolation and freeze durable Postgres SyncRun ownership after the revoked-sync terminal-safety regression showed that Event-ID-only cleanup is unsafe. |
| **Authority** | This file is the active contract for B0–B5 and the separate SyncRun ownership workstream R0–R6. P1-D and all v1.2 creation-authority semantics remain frozen. PR #514 stays blocked until the SyncRun ownership implementation is reviewed, merged, and verified. |
| **Accepted base** | `BASE_SHA=db8e5eb2a51bdbcc45fde2818c49b572e2c7ec53`, `BASE_TREE=3dc265243580bf52fd72fc6c734caf535723e52f` |
| **Tracking** | `FastCheckin-v6u9` (Beads / `bd`; verified locally 2026-10-09) |
| **Last updated** | 2026-10-09 |
| **Change summary (1.3)** | Freeze durable SyncRun ownership in sync_logs, owner fencing, one active run per Event, database-clock leases, per-request authorization, and bounded crash recovery; keep SyncRun implementation separate from PR #514. |
| **Change summary (1.2)** | Clarify creation authority: revalidate the current trusted dashboard identity and creation flag before bounded pre-insert Tickera credential/metadata resolution; forbid post-insert Event-owned operational work; require stale-identity and revoked-sync terminal-safety tests |
| **Change summary (1.1)** | Master-review corrections: preserve empty Event-grant semantics; freeze `DASHBOARD_EVENT_CREATION_ENABLED` parsing; require grant-scoped Event and attendee aggregate queries (no global `events:all` filter) |
| **Change summary (1.0)** | Initial authority freeze: existing-Event grants via `DASHBOARD_ALLOWED_EVENT_IDS`; creation via `DASHBOARD_EVENT_CREATION_ENABLED`; query-scoped dashboard list; decoupled create/sync; implementation slices B0–B5 |

### Revision log

- `1.3` — Freeze durable Postgres SyncRun ownership after the B1 revoked-sync terminal-safety regression showed Event-ID-only cleanup is unsafe. Define owner-fenced active-run semantics, atomic Event/run transitions, leases, request-boundary authority checks, bounded crash recovery, and stale-worker fencing. Preserve v1.2 creation authority.
- `1.2` — Clarify creation-input authority: the current trusted dashboard identity plus creation capability is required before any external validation; bounded pre-insert Tickera credential and Event-essentials discovery is permitted, while post-insert Event-owned operational work remains grant-gated. Add stale-identity and revoked-sync terminal-safety regression requirements.
- `1.1` — Master-review corrections: preserve empty Event-grant semantics, freeze creation-flag parsing, and require grant-scoped Event plus attendee aggregate queries without filtering the global Event cache.
- `1.0` — Authority freeze (documentation only). No production code.

---

## Problem statement

P1-D closed **Sales-specific** dashboard authorization: authenticated dashboard identities resolve to a **server-owned** Event grant set via `FastCheck.Sales.DashboardAccess`, backed by `DASHBOARD_ALLOWED_EVENT_IDS` in runtime configuration.

The **general** BrowserAuth surfaces under the same `:dashboard_auth` pipeline still load and mutate Events without consistent grant enforcement:

| Surface | Route / module | Current gap (baseline at accepted SHA) |
|---------|----------------|----------------------------------------|
| Root dashboard | `GET /`, `GET /dashboard` → `FastCheckWeb.DashboardLive` | `mount/3` calls `Events.list_events()` before grant resolution; UI partially gates Sales controls with `event_granted?` but list data and many `handle_event` paths are not grant-checked |
| Event creation | `DashboardLive` `"create_event"` | No separate creation capability; on success starts **full attendee sync** via `start_sync_task` |
| Exports | `GET /export/attendees/:event_id`, `GET /export/check-ins/:event_id` → `ExportController` | Fetches Event and CSV data with **no** `DashboardAccess` check |
| Browser scanner | `GET /scan/:event_id` → `ScannerLive` | Loads stats, occupancy, search, check-in/out, PubSub with **no** Event grant |
| Occupancy | `GET /dashboard/occupancy/:event_id` → `OccupancyLive` | Loads advanced stats and subscribes to PubSub with **no** Event grant |

**Central invariant to restore:**

```text
NO EXISTING EVENT MAY BE READ OR MUTATED WITHOUT
SERVER-OWNED PER-EVENT AUTHORITY.
```

Authentication (`BrowserAuth`) is **not** authorization.

---

## Frozen architectural decisions

These decisions are authoritative for implementation unless repository evidence directly contradicts them.

### 1. Existing-Event authority

```text
EXISTING_EVENT_AUTHORITY=DASHBOARD_ALLOWED_EVENT_IDS
```

- Single server-owned grant source for **all existing Event-owned** BrowserAuth operations (general dashboard, exports, browser scanner, occupancy).
- Resolved at runtime through existing `Application.get_env(:fastcheck, :dashboard_auth)` → `allowed_event_ids` (see `config/runtime.exs`).
- Re-validated on every operation via `FastCheck.Sales.DashboardAccess` (no refactor/rename in this workstream).

**Forbidden:**

```text
BROWSER_ALLOWED_EVENT_IDS
second Event allowlist
DB permission table
Redis permission authority
wildcard / all-events authority
browser/session-derived grants
per-row permission query as authority source
```

**`DASHBOARD_ALLOWED_EVENT_IDS` configuration contract** (unchanged P1-D / runtime semantics; do not tighten):

| Input | Result |
|-------|--------|
| missing / blank (`nil`, `""` after trim) | valid configuration → **empty** Event grant set → fail closed for Event-owned access |
| nonblank | comma-separated positive integer Event IDs → deduplicate + sort (`FastCheck.RuntimeConfiguration.dashboard_event_ids/1`) |
| malformed nonblank | configuration error → application fails at boot |

```text
DASHBOARD_ALLOWED_EVENT_IDS_REQUIRED_IN_PROD=NO
EMPTY_GRANT_SET_ALLOWED=YES
EMPTY_GRANT_SET_ACCESS=NONE
```

This variable is **not** a new production-required env var. Missing/blank grants zero Events; operators may still set explicit IDs when needed.

### 2. P1-D preservation

```text
REFACTOR_P1D_AUTHORITY=NO
RENAME_DASHBOARD_ACCESS=NO
CHANGE_P1D_PUBLIC_BEHAVIOR=NO
REUSE_EXISTING_GRANT_SEMANTICS=YES
```

`FastCheck.Sales.DashboardAccess` already:

- Re-resolves grants from configuration (never trusts actor-supplied `allowed_event_ids`).
- Exposes `actor_for_identity/1`, `allowed_event_ids/1`, `event_granted?/2`.

General BrowserAuth remediation **reuses** this module; neutralizing the `Sales` namespace is deferred.

### 3. Event creation authority

Creation has no pre-existing Event ID; it requires a **separate global** server-owned flag:

```text
EVENT_CREATION_CAPABILITY=DASHBOARD_EVENT_CREATION_ENABLED
```

**Parsing contract (frozen; B0 must not choose different semantics):**

Input preprocessing: trim whitespace, then lowercase (same vocabulary as `FastCheck.RuntimeConfiguration` `@strict_true` / `@strict_false`).

| Input | Creation allowed |
|-------|------------------|
| missing / blank | `false` |
| `1`, `true`, `yes`, `on` | `true` |
| `0`, `false`, `no`, `off` | `false` |
| any other nonblank value | configuration error → application fails closed at boot |

```text
EVENT_CREATION_TRUE_VALUES=1,true,yes,on
EVENT_CREATION_FALSE_VALUES=0,false,no,off
EVENT_CREATION_MISSING=false
EVENT_CREATION_BLANK=false
EVENT_CREATION_INVALID_NONBLANK=BOOT_ERROR
```

**Must not infer creation permission from:** role, query params, LiveView assigns, existing Event grants, or “has any allowed Event”.

Creation authority requires both current identity and the creation capability:

```text
CREATION_AUTHORITY=
CURRENT_TRUSTED_DASHBOARD_IDENTITY
AND
DASHBOARD_EVENT_CREATION_ENABLED
```

At the `DashboardLive` action boundary, re-resolve the authenticated dashboard identity through `DashboardAccess.actor_for_identity/1` against the current server configuration. A trusted actor assigned at mount is not sufficient: if that identity is no longer the currently configured trusted identity, the stale LiveView is denied. Revalidate both conditions immediately before any creation-time external request.

### 4. Creation input resolution and post-insert side effects

Creation requires the current trusted dashboard identity **and** the separate creation capability. Both must be revalidated at the action boundary before the first creation-time external request. A stale socket does not retain creation authority.

If the current identity is invalid or creation is disabled, deny terminally before any Event row, Tickera request, or cache mutation:

```text
CURRENT_IDENTITY_INVALID
→ EVENT_ROW=NO
→ TICKERA_REQUEST=NO
→ CACHE_MUTATION=NO
→ TERMINAL_DENIED

CREATION_FLAG_FALSE
→ EVENT_ROW=NO
→ TICKERA_REQUEST=NO
→ CACHE_MUTATION=NO
→ TERMINAL_DENIED
```

After both checks pass, creation may perform only the bounded pre-insert work already required by the `Events.create_event/1` domain contract. Call this work `CREATION_INPUT_RESOLUTION`:

```text
1. Tickera credential validation: TickeraClient.check_credentials/2
2. Tickera Event metadata discovery needed to construct the Event:
   TickeraClient.get_event_essentials/2
3. Local normalization, credential encryption, and changeset preparation
4. One durable Event-row insert
5. Internal Event cache persistence/invalidation needed for consistency
```

This bounded pre-insert validation and discovery does not grant authority over the Event. Do not broaden the permitted Tickera surface beyond the calls required by the existing creation contract. In particular, attendee-list retrieval (`tickets_info`) is not creation-input resolution.

After the Event row exists, creation itself must not automatically perform:

```text
full attendee sync
incremental attendee sync
tickets_info / attendee-list retrieval
automatic sync retry
WhatsApp Sales enablement
WhatsApp offer mutation
browser/session auto-grant
DASHBOARD_ALLOWED_EVENT_IDS mutation
scanner/mobile secret reveal
Event PubSub subscription
Event PubSub broadcast
other Event-owned external operational work
```

Freeze:

```text
CREATE_AUTO_SYNC=NO
CREATE_AUTO_WHATSAPP_ENABLE=NO
CREATE_AUTO_GRANT=NO
CREATE_POST_INSERT_EXTERNAL_EVENT_WORK=NO
```

**Operational state after successful creation:**

```text
EVENT_CREATED
→ CREATED_PENDING_SERVER_GRANT
```

The Event becomes ordinarily operable only when its ID is in the current server-owned `DASHBOARD_ALLOWED_EVENT_IDS` set (config change + deploy/restart per existing ops procedure).

**Edge case:** If the new Event’s ID was **pre-listed** in `DASHBOARD_ALLOWED_EVENT_IDS`, later requests may treat it as granted after insertion—but creation itself still must not auto-start sync or enable WhatsApp. Creation and synchronization remain separate operations.

**Baseline coupling to remove:** `DashboardLive.handle_event("create_event", …)` currently calls `start_sync_task(event.id, incremental: false)` after create (see accepted SHA).

### 5. Existing-Event mutations

Every action with a target Event ID requires normal Event grant. **No** global “event management” bypass.

Minimum mutation classes on `DashboardLive` (and any shared helpers):

```text
edit/update
archive / unarchive
permanent removal (archived)
full / incremental sync start
pause / resume / cancel sync
sync history view
scanner/mobile secret reveal (password challenge + decrypt + assign + render)
WhatsApp Sales enable/disable on Event
```

Denial **before** DB mutation, Oban enqueue, `Task` start, external sync, decryption, PubSub subscribe/broadcast.

### 6. Root dashboard reads (query boundary)

**Do not** load all Events and filter in LiveView memory or in Elixir after a global fetch.

**Baseline trap (accepted SHA):** `FastCheck.Events.Cache.list_events/0` uses global cache key `events:all`. Its cold path (`fetch_events_from_db/0`) performs (1) an attendee rollup across **all** attendee `event_id` values, then (2) `Repo.all` on **all** Events—before any dashboard grant is applied.

Implement a grant-scoped query primitive (name illustrative):

```text
Events.list_events_by_ids(granted_event_ids)
```

**Explicit prohibitions for B0/B1:**

```text
MUST NOT call Cache.list_events/0 and then filter by granted IDs.
MUST NOT read events:all as the source of an authorization-scoped list.
MUST NOT execute an attendee rollup across ungranted Events.
```

Forbidden pattern (presentation filtering over unauthorized data):

```elixir
Cache.list_events()
|> Enum.filter(&(&1.id in granted_ids))
```

#### Empty grant set

```text
list_events_by_ids([])
→ []

DB_CALLS=0
EVENTS_ALL_CACHE_READ=NO
ATTENDEE_ROLLUP_QUERY=NO
```

No database or global Event-list cache access when authority grants no Events.

#### Non-empty grant set

Scope **every** Event-owned query to the grant set. Two bounded set-based DB queries are acceptable (do not force a single artificial join).

```text
ATTENDEE_ROLLUP_QUERY:
  WHERE attendee.event_id IN ^granted_event_ids
  GROUP BY attendee.event_id

EVENT_QUERY:
  WHERE event.id IN ^granted_event_ids
  (preserve current dashboard ordering, e.g. desc inserted_at)
```

Preserve current dashboard list fields for **granted** Events only: Event ordering, `attendee_count`, `checked_in_count`. No ungranted Event row or aggregate may be loaded as part of the dashboard list operation.

```text
BOUNDED_SET_BASED_QUERIES=YES
ALL_EVENT_SCAN=NO
ALL_ATTENDEE_ROLLUP=NO
N_PLUS_ONE=NO
PER_EVENT_AUTHORITY_QUERY=NO
SCOPED_LIST_USES_GLOBAL_EVENTS_CACHE=NO
EVENT_QUERY_SCOPED_BY_GRANTS=YES
ATTENDEE_ROLLUP_SCOPED_BY_GRANTS=YES
```

`Event.id` is primary-key indexed; **no new index expected**.

#### Cache decision (B0)

```text
NEW_SCOPED_LIST_CACHE=NO
REDIS_REQUIRED=NO
CACHEX_REQUIRED=NO
```

Do not introduce per-grant-set cache keys. Do not reuse `events:all` for the secured dashboard list. Bounded scoped DB reads are preferable to caching unauthorized rows into the authorization path. Existing global caches used by other already-authorized paths are not removed in B0.

### 7. Authority sequence (controllers and LiveViews)

```text
AUTHENTICATED                    # BrowserAuth (:dashboard_auth)
  → TRUSTED_DASHBOARD_IDENTITY   # DashboardAccess.actor_for_identity
  → EVENT_ID_PARSED              # when applicable
  → CURRENT_SERVER_GRANT_RESOLVED
  → EVENT_GRANTED | EVENT_DENIED
```

If `EVENT_GRANTED`:

```text
READ  → READ_ALLOWED
MUTATE → MUTATION_GRANT_RECHECK → MUTATION_ALLOWED
```

If `EVENT_DENIED`:

```text
EVENT_DENIED → TERMINAL_NO_SIDE_EFFECTS
```

Denial must occur **before:**

```text
DB mutation
Oban enqueue
Task / sync start
CSV generation / response body
check-in/out mutation
secret decrypt / plaintext assign
PubSub subscribe or broadcast
Event-owned external API call
```

### 8. LiveView stale-state rule

Grant checks are **not** mount-only. Every `handle_event` (and `handle_info` that mutates or discloses Event-owned data) must revalidate grant for the effective Event ID from:

```text
phx-value-event_id
socket.assigns.event_id
editing_event_id / selected_event_id
loaded Event structs
forged or stale IDs from another tab
```

### 9–12. Surface boundaries (frozen)

| Slice | Routes | Grant before |
|-------|--------|----------------|
| **Scanner (browser)** | `/scan/:event_id`, `ScannerLive` | attendee search, stats/occupancy, check-in/out, PubSub |
| **Occupancy** | `/dashboard/occupancy/:event_id`, `OccupancyLive` | Event lookup beyond safe routing, aggregates, PubSub |
| **Export** | `/export/attendees/:event_id`, `/export/check-ins/:event_id` | export queries, CSV bytes, filename metadata |
| **Secret reveal** | `DashboardLive` reveal/edit-reveal flows | challenge success, decrypt, assigns, render |

**Explicit non-scope (unless shared vulnerable code forces narrow fix):**

```text
/scanner/:event_id          # :scanner_auth portal
/api/v1/mobile/*           # mobile JWT event scope
P1-D Sales LiveViews       # already gated; regression tests must stay green
```

**Export denial semantics:** ungranted or non-existent Event → same **safe not-found class** as unavailable Event: no CSV headers, no partial bytes, no filename leakage, no Event metadata disclosure.

---

## Authority hierarchy

```text
Layer 1 — Transport/session
  BrowserAuth → authenticated dashboard username in session

Layer 2 — Identity → grant resolution (cold config, hot membership)
  DashboardAccess.actor_for_identity(username)
  allowed_event_ids ← DASHBOARD_ALLOWED_EVENT_IDS (runtime)

Layer 3 — Creation (no Event ID yet)
  revalidate current authenticated identity with DashboardAccess.actor_for_identity/1
  AND require DASHBOARD_EVENT_CREATION_ENABLED
  → bounded CREATION_INPUT_RESOLUTION
  → one Event-row insert
  → CREATED_PENDING_SERVER_GRANT

Layer 4 — Per-Event enforcement (every existing Event operation)
  DashboardAccess.event_granted?(actor, event_id)

Layer 5 — Sensitive sub-operations
  Existing password challenge for secret reveal remains;
  it does NOT substitute for Layer 4.
```

---

## Scope

**In scope:**

- General `DashboardLive` list, mutations, sync controls, secret reveal, WhatsApp toggles on Event
- `ExportController` attendee and check-in CSV exports
- `ScannerLive` browser scanner
- `OccupancyLive` dashboard occupancy
- Config parsing for `DASHBOARD_EVENT_CREATION_ENABLED`
- Query primitive `list_events_by_ids/1` (or equivalent in Events context/cache layer)
- Tests per matrix below
- Docs updates in slice B5 only where implementation proves gap closure

**Out of scope:**

- Refactoring `DashboardAccess` module name or P1-D Sales route behavior
- Mobile JWT scanner contract changes
- `scanner_auth` portal redesign
- Redis/Cachex/DB permission stores
- Cancelling in-flight sync solely because grant was removed later (unless domain already requires it)
- Modifying launch runbooks / risk registers in this plan-only PR

---

## Resource map (implementation targets)

| Resource | Location (baseline) | Enforcement hook |
|----------|---------------------|------------------|
| Dashboard root | `lib/fastcheck_web/live/dashboard_live.ex` | mount + all `handle_event` / relevant `handle_info` |
| Event list query | `lib/fastcheck/events.ex` → `Cache.list_events/0` | new `list_events_by_ids/1` |
| Runtime config | `config/runtime.exs`, `FastCheck.RuntimeConfiguration` | `DASHBOARD_EVENT_CREATION_ENABLED` |
| Grants | `lib/fastcheck/sales/dashboard_access.ex` | reuse unchanged public API |
| Exports | `lib/fastcheck_web/controllers/export_controller.ex` | plug or private `with_grant` before queries |
| Scanner | `lib/fastcheck_web/live/scanner_live.ex` | mount + events affecting Event data |
| Occupancy | `lib/fastcheck_web/live/occupancy_live.ex` | mount + `handle_info` |
| Router | `lib/fastcheck_web/router.ex` | remain `:browser`, `:dashboard_auth`; optional shared plug in B0 if it reduces duplication without widening access |

---

## State machines

### Event creation lifecycle

```text
CURRENT_IDENTITY_INVALID
  → terminal: no Event row, Tickera request, or cache mutation

CREATION_FLAG_FALSE
  → terminal: no Event row, Tickera request, or cache mutation

CURRENT_TRUSTED_DASHBOARD_IDENTITY
AND DASHBOARD_EVENT_CREATION_ENABLED
  → CREATION_INPUT_RESOLUTION (bounded pre-insert validation/discovery)
  → EVENT_CREATED (one durable Event row + internal cache consistency only)
  → CREATED_PENDING_SERVER_GRANT

CREATED_PENDING_SERVER_GRANT
  → (operator adds ID to DASHBOARD_ALLOWED_EVENT_IDS + restart)
  → CONFIG_GRANT_APPLIED
  → EVENT_GRANTED

EVENT_GRANTED
  → edit, archive, sync, export, scanner, occupancy, secret reveal, Sales toggles
```

### Per-request authorization

```text
AUTHENTICATED
  → grant resolve
  → EVENT_GRANTED → operation-specific allow
  → EVENT_DENIED  → TERMINAL_NO_SIDE_EFFECTS (flash/redirect/404 per surface)
```

---

## Authorization invariants

1. **Server-owned grants only** — `DASHBOARD_ALLOWED_EVENT_IDS` is the sole existing-Event authority.
2. **No auto-grant on create** — new Event IDs never appended to allowlist by application code.
3. **No auto-sync on create** — sync is an explicit granted mutation.
4. **Query-scoped listing** — ungranted Events never loaded into dashboard process for list/aggregates.
5. **Re-check on every LiveView event** — mounts are hints, not locks.
6. **Fail closed** — malformed grants or creation flag → deny or boot error per config rules.
7. **P1-D unchanged** — Sales tests and behavior remain green.
8. **Deny before side effects** — especially Oban, Tasks, PubSub, CSV, decrypt.

---

## Event creation policy (configuration contract)

| Variable | Purpose | Default / semantics |
|----------|---------|---------------------|
| `DASHBOARD_ALLOWED_EVENT_IDS` | Existing-Event read/mutate/export/scanner/occupancy/reveal | missing/blank → valid, **empty grant set**, fail closed; nonblank → comma-separated positive integers (dedupe + sort); malformed nonblank → boot error |
| `DASHBOARD_EVENT_CREATION_ENABLED` | Creation capability; requires current trusted dashboard identity and permits bounded creation-input resolution plus one Event insert | missing/blank → **false**; see frozen parser in §3 (`1`/`true`/`yes`/`on` vs `0`/`false`/`no`/`off`; other nonblank → boot error) |

```text
DASHBOARD_ALLOWED_EVENT_IDS_REQUIRED_IN_PROD=NO
```

---

## Route / action matrix (target behavior)

| Route / action | Auth pipeline | Event grant | Creation flag |
|----------------|---------------|-------------|---------------|
| `/`, `/dashboard` list | dashboard_auth | grant set scopes query | — |
| `create_event` | dashboard_auth plus current identity revalidation via `DashboardAccess.actor_for_identity/1` | — | required |
| `update_event`, archive, unarchive, remove | dashboard_auth | required | — |
| sync * | dashboard_auth | required | — |
| secret reveal * | dashboard_auth | required (+ existing password challenge) | — |
| WhatsApp enable/disable on Event | dashboard_auth | required | — |
| `/export/*/:event_id` | dashboard_auth | required | — |
| `/scan/:event_id` | dashboard_auth | required | — |
| `/dashboard/occupancy/:event_id` | dashboard_auth | required | — |
| Sales routes under `/dashboard/sales/*` | dashboard_auth | P1-D (unchanged) | — |
| `/scanner/:event_id` | scanner_auth | **out of scope** | — |
| `/api/v1/mobile/*` | mobile_api JWT | **out of scope** | — |

---

## Side-effect guards

| Side effect | Guard |
|-------------|-------|
| Event row insert | Current trusted dashboard identity **and** creation flag, revalidated before creation-input external requests |
| Existing Event update/delete | Current per-Event grant |
| Creation-time Tickera credential/essentials request | Current trusted dashboard identity **and** creation flag, revalidated immediately before the request |
| `start_sync_task` / sync Task | grant |
| Oban jobs for Event | grant at enqueue time |
| `Attendees` check-in/out (scanner) | grant before mutation |
| CSV `send_resp` | grant before query |
| Secret decrypt | grant before decrypt |
| `PubSub.subscribe` | grant before subscribe |
| WhatsApp Sales enable | grant (creation path must not call) |

---

## Denial semantics

| Surface | Ungranted Event | Invalid ID |
|---------|-----------------|------------|
| Dashboard list | not in query result | — |
| Dashboard `handle_event` | no-op / error flash; no DB/Task/Oban | parse error |
| Export | 404 JSON (no CSV) | 400/404 per existing patterns |
| ScannerLive | redirect or error before data/PubSub | same as missing Event |
| OccupancyLive | redirect before stats/PubSub | same as missing Event |
| Secret reveal | deny before decrypt | deny |

Avoid distinguishing “exists but ungranted” vs “missing” in export/scanner responses where that would leak existence.

---

## Performance and scaling review

```text
GRANT_SOURCE=Application runtime configuration
GRANT_LAYER=COLD configuration at boot
ENFORCEMENT_LAYER=HOT in-process list membership (allowed_event_ids)
REDIS_REQUIRED=NO
CACHEX_REQUIRED=NO
NEW_GEN_SERVER_REQUIRED=NO
NEW_DB_PERMISSION_TABLE=NO
NEW_DB_PERMISSION_QUERY_PER_REQUEST=NO
NEW_INDEX_EXPECTED=NO
```

Root list: **bounded set-based queries** scoped to `granted_event_ids` (Event rows + attendee rollups)—not `ALL_EVENT_SCAN`, not `ALL_ATTENDEE_ROLLUP`, not N+1 per-Event authority queries, not load-all-then-filter, not `events:all` cache as source.

---

## Concurrency and failure modes

| Scenario | Expected behavior |
|----------|-------------------|
| Empty grant set | Dashboard list empty; all Event operations denied |
| Malformed `DASHBOARD_ALLOWED_EVENT_IDS` | Boot fail (existing) |
| Malformed creation flag | Boot fail closed |
| Current dashboard identity no longer trusted | `create_event` denied; no row, Tickera request, or cache mutation |
| Creation disabled | `create_event` denied; no row, Tickera request, or cache mutation |
| Forged `event_id` in LiveView event | Denied; no mutation |
| Stale socket / second tab | Re-check grant on each event |
| Event deleted after mount | Operation fails safely; no leak |
| Grant removed after mount | New operations denied; do not cancel authorized in-flight sync unless domain requires |
| Sync running when grant removed | Do not auto-cancel (unless existing invariant says otherwise) |
| Ungranted export/scanner/occupancy/reveal | Deny before disclosure |
| Preconfigured future Event ID in allowlist | Granted only after Event exists; create still no auto-sync |

---

## Test matrix (required before closing P0)

**Grant dimensions:** A-only, A+B, empty grants, malformed configuration.

**Root dashboard:**

- A visible; B absent from query assigns
- B aggregates absent
- Forged B `handle_event` denied

**Creation:**

- stale/untrusted dashboard identity with flag true → denied; zero Tickera requests and zero Event rows
- current trusted identity with flag false → denied; zero Tickera requests and zero Event rows
- current trusted identity with flag true → bounded credential check and Event-essentials discovery may run; Event row created and marked pending server grant
- successful create → no `tickets_info`/attendee sync request, no auto-sync, no auto-grant, and no WhatsApp enable from create path

**Revoked sync terminal safety:**

- granted sync starts and reaches running state
- grant is removed, then the worker fails, throws, or times out
- no retry or new external request starts
- durable Event leaves `syncing`, the SyncRun row is terminal, and matching hot SyncState is cleared
- if this test fails, stop and report the cleanup semantics needed; this requirement does not authorize a production-code change by itself

**Mutations (each class):** A granted → baseline behavior; B ungranted → denied; DB/Oban/Task unchanged; secret not decrypted.

**Exports:** A → CSV; B → safe not-found before body.

**Scanner:** A → baseline; B → denied before data/PubSub; forged scan → zero check-in mutation.

**Occupancy:** A → baseline; B → denied before stats/PubSub.

**Regression:**

- `FastCheck.Sales.DashboardAccessTest` and P1-D Sales LiveView/controller tests green
- Mobile JWT scanner unchanged
- `scanner_auth` portal unchanged

---

## Implementation slices

Each slice must preserve fail-closed behavior **before** later slices land. Document any temporary dependency (e.g. B1 before B2) in PR descriptions.

| Slice | Contents | Depends on |
|-------|----------|------------|
| **B0** | `DASHBOARD_EVENT_CREATION_ENABLED` parsing (frozen strict boolean vocabulary); shared grant helper(s) if needed; `Events.list_events_by_ids/1` with grant-scoped Event + attendee rollup queries (empty grants → `[]`, zero DB/cache); unit tests for config + query | — |
| **B1** | `DashboardLive` query-scoped mount/refresh; grant on all Event `handle_event`; creation policy including current identity revalidation and bounded creation-input resolution; **remove create→sync coupling** | B0 |
| **B2** | `ExportController` grant enforcement + tests | B0 |
| **B3** | `ScannerLive` grant enforcement + tests | B0 |
| **B4** | `OccupancyLive` grant enforcement + tests | B0 |
| **B5** | Integration/security closure; update operator docs/runbooks **only** with implementation evidence | B1–B4 |

**Do not** implement B0+ in this plan-only change.

---

## STOP conditions (implementation phase)

Stop and escalate if:

```text
origin/main diverges from agreed base without rebase review
a slice requires a second Event allowlist or DB permissions
a slice weakens P1-D Sales tests
grant checks would occur only in templates (:if) without handle_event guards
dashboard list reverts to list_events() + filter
list_events_by_ids uses Cache.list_events/0 or events:all then filters
attendee rollup runs across ungranted Events for dashboard list
creation auto-starts sync or mutates allowlist
```

---

## Tracking verification

| Field | Value |
|-------|-------|
| **TRACKING_ID** | `FastCheckin-v6u9` |
| **TRACKING_SOURCE** | Local Beads issue tracker (`bd show FastCheckin-v6u9`, 2026-10-09) |
| **Title** | P0: Isolate general BrowserAuth surfaces by Event |
| **Depends on** | `FastCheckin-3g31` (P1-D) — closed |

GitHub/Linear/Plane were not required for this identifier; Beads is the repository’s configured tracker.

---

## Historical baseline evidence (v1.0 accepted SHA)

This snapshot records the v1.0 baseline at `a56d2cc0e119ae84d1509e508486d19ee5e12663`; it is historical, not the current accepted base:

- `DashboardLive.mount/3` — `Events.list_events()` then `DashboardAccess.actor_for_identity/1`
- `DashboardLive` `"create_event"` — `Events.create_event/1` then `start_sync_task/2`
- `ExportController` — `fetch_event/1` only
- `ScannerLive.mount/3` — `fetch_event/1`, stats, PubSub not grant-gated
- `OccupancyLive.mount/3` — stats + PubSub not grant-gated
- `config/runtime.exs` — `DASHBOARD_ALLOWED_EVENT_IDS` → `:dashboard_auth.allowed_event_ids` (`nil`/blank → `[]`)
- `lib/fastcheck/events/cache.ex` — `events:all`, global attendee rollup + all Events on cold path
- P1-D module — `lib/fastcheck/sales/dashboard_access.ex`

---

## Success criteria (implementation complete)

```text
EXISTING EVENTS → per-Event allowlist only (DASHBOARD_ALLOWED_EVENT_IDS)
NEW EVENT CREATION → CURRENT_TRUSTED_DASHBOARD_IDENTITY AND DASHBOARD_EVENT_CREATION_ENABLED
NEW EVENT → no grant and no sync as side effect of creation
ROOT LIST → query-scoped by granted IDs
ALL LISTED ROUTES → grant before side effects
P1-D → unchanged behavior and tests
NO Redis / permission DB / new index for grants
```

---

## Plan-only PR gate

This document version `1.3` / `FROZEN` is the repository authority contract once merged to `main`. P1-D and v1.2 creation authority remain frozen. The separate SyncRun ownership implementation must merge and pass post-merge CI before PR #514 resumes. Do not implement SyncRun ownership in this authority change.

## v1.3 durable SyncRun ownership authority

This section is normative for the future sync lifecycle workstream. It supplements the BrowserAuth and creation rules above. It does not authorize production implementation in this documentation change. The future SyncRun implementation is a separate prerequisite to resuming PR #514.

```text
SYNC_RUN_DURABLE_AUTHORITY=Postgres
SYNC_RUN_STORAGE=existing sync_logs table
SYNC_RUN_HOT_MIRROR=FastCheck.Events.SyncState
SYNC_RUN_EXTERNAL_LOCK=NONE
REDIS_REQUIRED=NO
LONG_DB_LOCK_DURING_TICKERA_CALL=NO
AT_MOST_ONE_DURABLE_ACTIVE_RUN_PER_EVENT=YES
```

The v1.2 revoked-sync test remains required. Its failure exposed that an Event-ID-only reset cannot safely clean up a run after authority revocation. v1.3 replaces the v1.2 stop-only disposition for that lifecycle finding with the dedicated R0–R6 design below. It does not change v1.2 creation authority, P1-D, exports, scanner, occupancy, or the B2–B4 boundaries.

### Durable resource model

Postgres is the durable authority for sync-run ownership. Reuse the existing `sync_logs` table as both the operational SyncRun ledger and the audit record. Do not add a second operational run table. `FastCheck.Events.SyncLog` remains the schema and history representation. A future `FastCheck.Events.SyncRun` service may own claims, leases, fencing, control transitions, terminalization, and recovery.

Every new active SyncRun must persist:

```text
sync_run_id       UUID
owner_token       UUID
lease_expires_at  timestamptz
heartbeat_at      timestamptz
```

Historical terminal rows may leave ownership fields null. Every new active row must have `sync_run_id`, `owner_token`, `lease_expires_at`, and `heartbeat_at`. The existing sync path already creates a UUID `sync_run_id` for attendee reconciliation. Persist that same run identifier on `sync_logs`; it identifies the logical run and remains distinct from the owner token. Continue passing `sync_run_id` to reconciliation and invalidation code; never persist `owner_token` in attendee or invalidation rows. Generate a separate random, unguessable `owner_token` once per run. Keep the owner token immutable, server-only, and out of browser responses. Do not derive it from an Event ID, username, process identifier, node name, or socket.

The `SyncState` Agent is a hot mirror only. It does not prove ownership and it may be rebuilt or discarded. Each entry identifies `event_id`, `sync_run_id`, `owner_token`, status, current page, total pages, and attendees processed. Postgres wins if the mirror disagrees.

`DashboardLive` is a UI/controller. It may start or control a run only after checking the current trusted dashboard identity and Event grant. The LiveView process and its socket do not own the run. A sync worker owns one run by the pair `sync_run_id + owner_token`. A bounded system recovery worker may terminalize an expired run but may not start or retry Tickera work.

### Statuses and Event mapping

Preserve the existing `sync_logs.status` vocabulary. Active and terminal statuses are:

```text
ACTIVE_SYNC_RUN_STATUSES=in_progress,paused
TERMINAL_SYNC_RUN_STATUSES=completed,failed,cancelled
```

Do not persist a `claiming` status. Claiming exists only within a short Postgres transaction. A paused run remains active for uniqueness and lease purposes.

```text
in_progress -> Event.status=syncing
paused      -> Event.status=syncing
completed   -> terminal
failed      -> terminal
cancelled   -> terminal
```

Terminalization may change `Event.status` from `syncing` to `active` only if the Event still has status `syncing`. It must never change `archived` or any other non-syncing lifecycle state to `active`. A terminal run never becomes active again. Resuming work after lease expiry requires a new run row and a new owner token.

### Database invariants and migration safety

Postgres must enforce:

```text
AT_MOST_ONE_ACTIVE_SYNC_RUN_PER_EVENT
```

Use a partial unique index equivalent to:

```sql
CREATE UNIQUE INDEX sync_logs_one_active_run_per_event_index
ON sync_logs (event_id)
WHERE status IN ('in_progress', 'paused');
```

Use stable, explicit names for these indexes. Logical run UUIDs must also be unique:

```sql
CREATE UNIQUE INDEX sync_logs_sync_run_id_unique_index
ON sync_logs (sync_run_id)
WHERE sync_run_id IS NOT NULL;
```

The recovery index must support bounded expiry scans:

```sql
CREATE INDEX sync_logs_active_lease_expiry_index
ON sync_logs (lease_expires_at)
WHERE status IN ('in_progress', 'paused');
```

Add a database CHECK constraint requiring non-null `sync_run_id`, `owner_token`, `lease_expires_at`, and `heartbeat_at` whenever status is `in_progress` or `paused`. Postgres primary-database constraints and transactions are the cross-node concurrency authority. Do not use Redis or Cachex for ownership, and do not read ownership from a replica.

Before the implementation migration adds the unique index, inspect existing data for multiple active rows per Event, expired `in_progress` or `paused` rows, and active rows inconsistent with Event status. Do not silently rewrite or delete historical rows to make the index pass. Unexpected active data requires:

```text
STOP=MIGRATION_ACTIVE_RUN_RECONCILIATION_REQUIRED
```

The implementation plan must define how operators resolve such data before migration. The recovery index must support bounded expiry scans without a table scan.

### Atomic claim

Starting a run requires a current trusted dashboard identity, a current Event grant, a syncable Event, and no live active run. Revalidate the Event grant immediately before claim. Because dashboard configuration is not part of the database transaction, check it again before the first Tickera request.

Claim a run in one short transaction:

```text
BEGIN
lock the target Event row for update
verify the Event is syncable
inspect the active SyncRun for the Event
if an expired active run exists, terminalize it as failed / lease_expired
insert a new in_progress SyncRun with a fresh sync_run_id, a distinct owner_token, and a database-clock lease
set Event.status=syncing
COMMIT
```

All claim, takeover, terminalization, and recovery transactions use the same lock order: Event row first, then the matching SyncRun row. This avoids claim-versus-cleanup lock inversion for the same Event.

A live owner makes the claim fail with `{:error, :sync_already_running}`. The partial unique index is the final race backstop. An Event already marked `syncing` without an active run is inconsistent legacy data. Do not claim over it or reset it by Event ID; stop for explicit reconciliation. No Tickera request starts before the claim commits. Never hold the Event lock, a database connection, or a transaction across Tickera I/O.

An expired run may be terminalized in the same authorized claim transaction before inserting its replacement. The old row becomes failed with reason `lease_expired`. The new run receives a new row ID and a new owner token. The operation remains subject to the partial unique index and row locks.

### Owner fencing

Every SyncRun mutation must match both `sync_run_id` and `owner_token`. This applies to lease renewal, heartbeat, progress, cursor/checkpoint, pause, resume, cancellation, retry state, completion, failure, and terminal cleanup. Every owner-scoped update must check the affected-row result. A stale owner returns `{:error, :stale_owner}` or a deterministic no-write equivalent.

A stale owner cannot mutate the SyncRun, Event sync status, `SyncState`, progress, or control state. It cannot dispatch another Tickera request. Event ID alone is never ownership proof.

Dashboard control requests carry no owner token from the browser. The server first checks the current dashboard identity and Event grant, then resolves and locks the exact active run for that Event inside the SyncRun service. The service uses the persisted token in the owner-scoped transaction. Do not expose the token in HTML, LiveView assigns sent to the client, logs, or API responses.

Takeover never rotates a token on an existing run. An expired run becomes terminal `failed / lease_expired`; an authorized new start inserts a new active row with a new ID and token. A stale process can never become valid again.

### Lease and heartbeat

Freeze these values:

```text
SYNC_RUN_LEASE_TTL=180 seconds
SYNC_RUN_HEARTBEAT_INTERVAL=30 seconds
SYNC_RUN_RECOVERY_SCAN_INTERVAL=60 seconds
SYNC_RUN_RECOVERY_BATCH_SIZE=100
```

The ordinary Tickera HTTP timeout is 30 seconds and the existing outer sync-attempt timeout is 120 seconds. The lease exceeds both while still bounding recovery after a worker crash. All lease comparisons and extensions use the Postgres database clock, not application-node clocks.

Renewal must conditionally match the run ID, owner token, active status, and `lease_expires_at > database_now`. Set `heartbeat_at=database_now` and `lease_expires_at=database_now + 180 seconds`. An expired owner cannot renew itself. `EXPIRED_LEASE_RESURRECTION=FORBIDDEN`.

The worker owns a linked heartbeat process or equivalent. Every 30 seconds it rechecks current Event grant and durable ownership, then renews the lease only while both remain valid. The heartbeat dies with its worker. It must not be detached or extend the lease of a dead worker. A paused run continues its heartbeat and lease while the current grant remains valid. Grant revocation stops renewal and enters the revocation terminal path. Loss of durable ownership stops renewal, writes, and external requests.

### Tickera request and response boundaries

Before every sync-owned Tickera HTTP request, including Event-essentials lookup and every `tickets_info` page, the worker must check immediately before dispatch:

```text
current server-owned Event grant
matching SyncRun owner token
active SyncRun status
unexpired lease, renewed if needed
```

A check before a prior request or page cannot authorize the next request. No long-lived database lock may be used to span the network request.

A request dispatched while authority and ownership were valid may finish after a grant is revoked. After its response returns, recheck both current Event grant and SyncRun ownership before applying the response, changing progress or cursor, dispatching another request, retrying, or completing successfully.

If authority is revoked while a request is in flight, discard that response for further sync-domain work. Do not write attendees, reconciliation results, Event totals, progress, or completion from that response. Do not issue another request or retry. Terminalize the exact run as `cancelled` with reason `authority_revoked`, then perform only owner-scoped lifecycle cleanup. This cleanup is system authority for that run, not renewed user authority.

A response does not itself authorize database writes. For a response accepted while authority and ownership remain valid, page data and its durable checkpoint must not get out of step. Incomplete runs must not be marked successfully complete or run full reconciliation against a partial fetched set. Writes committed while authority was valid remain valid; a later revocation does not retroactively authorize further writes.

### Retry, pause, resume, and cancellation

Retries stay inside the same active run with the same run ID and owner token. Before each retry, recheck current Event grant, owner token, active status, and lease. If any check fails, do not retry. Do not reset the Event to active between authorized attempts or release active-run uniqueness during retry.

Pause transitions `in_progress -> paused`. The run remains active, the Event remains `syncing`, the token stays unchanged, and the lease heartbeat continues while authority remains valid. No new Tickera request may start while paused. If a request was already in flight when pause took effect, its response may be applied only after authority and ownership checks; pause takes effect before the next request.

Resume requires current Event grant, matching owner, `paused` status, and an unexpired lease. Transition `paused -> in_progress` and update the hot mirror only after the durable transition succeeds. Expired leases cannot resume.

User cancellation requires current Event grant and the exact active run. In one short transaction, set the run to terminal `cancelled / user_cancelled` and change Event `syncing -> active` if it still has that status. After commit, stop the worker and clear only the matching `SyncState`. A late response from the cancelled worker is discarded. No request or write starts after cancellation.

### Terminalization and Event safety

Use one owner-scoped terminalization operation with run ID, owner token, terminal status, and terminal reason. In a short transaction, lock the Event first, then lock the matching active run, verify the exact ID and token, mark that run terminal, and conditionally change the Event from `syncing` to `active`. The run and Event transitions commit atomically. Do not perform HTTP calls in this transaction.

After commit, clear only the `SyncState` entry matching Event ID, run ID, and owner token, then invalidate the relevant Event/list caches. A stale owner receives `:stale_owner` and touches neither the Event nor another run's mirror. If the Event has become archived or another non-syncing state, terminalize the owned run but leave the Event state unchanged.

Terminal reason precedence is:

```text
successful completion                    -> completed
user cancellation                        -> cancelled / user_cancelled
authority revoked during a run           -> cancelled / authority_revoked
worker failure while authority is valid  -> failed / recorded failure reason
expired lease or crash recovery          -> failed / lease_expired
```

If an in-flight Tickera request fails after authority was revoked, `authority_revoked` wins. No retry follows.

### SyncState mirror contract

All mutating hot-state operations must receive the Event ID, SyncRun ID, and owner token. This includes initialization, progress, pause, resume, cancel, clear, and continuation checks. A mismatched owner makes no change and returns a deterministic stale-owner result where the caller needs it.

When durable and hot state both change, update Postgres first. Only mirror the change in `SyncState` after the owner-scoped database operation succeeds. A stale-owner result means no hot-state mutation. `SyncState` never proves ownership. An old worker cannot overwrite or clear a newer run's state, even when both runs belong to the same Event.

### Worker, LiveView, and recovery behavior

A worker exit may trigger immediate owner-scoped failure terminalization if a supervising process still holds the exact run ID and owner token. Process monitors alone are not durable recovery. If no process terminalizes the run, the heartbeat stops and the lease expires.

A LiveView exit does not cancel a healthy worker. If the worker remains alive, its lease is valid, and the current Event grant remains valid, it may continue. No database connection or lock remains open because a LiveView disconnected.

Use a bounded Oban recovery worker to find active runs whose lease has expired. It scans every 60 seconds and processes at most 100 candidate Events per batch using the active status and database-clock expiry predicates backed by the recovery index. For each candidate, a short transaction locks the Event with `FOR UPDATE SKIP LOCKED`, then locks and rechecks the exact SyncRun row and `lease_expires_at <= database_now`. A renewed or terminal run is skipped. An expired run becomes `failed / lease_expired`; its Event changes from `syncing` to `active` only if the status still equals `syncing`. After commit, attempt matching hot-state cleanup. Recovery issues zero Tickera requests and starts zero retries.

Authorized takeover is a new explicit start by a currently trusted dashboard identity with a current Event grant. The claim transaction terminalizes any expired old run and inserts a fresh run ID and token. The recovery worker never takes over or resumes external work. Row locks and the partial unique index serialize recovery and takeover.

### Legacy Event-ID-only reset

`Events.force_reset_sync/2` and `FastCheck.Events.Sync.force_reset_sync/2` are not valid SyncRun ownership primitives. The future implementation must audit every caller. Every active-run lifecycle caller must move to owner-scoped terminalization before SyncRun ownership is accepted. The implementation plan must decide whether the legacy function is removed, made private, or retained only for non-owned maintenance. It must not remain the normal active-run retry, failure, cancellation, or cleanup path.

Existing SyncLog progress, completion, failure, pause, and cancel writes for an active run must also become owner-scoped. Do not load an active log by ID and apply unconditional updates. Every such update must include the run ID, owner token, and expected active state.

### Race outcomes

| Race | Required result |
|-------|-----------------|
| Two simultaneous starts | One claim succeeds; the other gets `sync_already_running`; one active row exists. |
| Paused run plus second start | Paused counts as active; second claim is denied. |
| Old worker after takeover | Old token is stale; progress, cleanup, mirror mutation, and next request are denied. |
| Old response after cancellation | Discard response; no domain write or completion overwrite. |
| Grant revoked during request | Current request may finish; discard its response; no next request or retry; cancel as `authority_revoked`. |
| Grant restored after revocation | Old run stays terminal; a new explicit start creates a new ID and token. |
| LiveView exits while worker remains healthy | Worker continues only while lease, owner, and grant checks pass. |
| Worker exits while LiveView remains | Exact owner may terminalize immediately; otherwise expiry recovery handles it. |
| LiveView and worker both exit | Lease expires; recovery terminalizes; Event does not remain `syncing`. |
| Recovery races authorized takeover | Row locks and the partial unique index serialize old-run terminalization and new claim. |
| Event is archived during cleanup | Run terminalizes; cleanup does not unarchive the Event. |

### Normative state machine

```text
NO_ACTIVE_RUN
  └─ authorized atomic claim ─> IN_PROGRESS

IN_PROGRESS
  ├─ pause ──────────────────> PAUSED
  ├─ success ────────────────> COMPLETED [terminal]
  ├─ final failure ─────────> FAILED [terminal]
  ├─ user cancel ───────────> CANCELLED [terminal]
  ├─ authority revoked ─────> CANCELLED [terminal]
  └─ lease expires ─────────> FAILED [terminal]

PAUSED
  ├─ resume ─────────────────> IN_PROGRESS
  ├─ user cancel ───────────> CANCELLED [terminal]
  ├─ authority revoked ─────> CANCELLED [terminal]
  └─ lease expires ─────────> FAILED [terminal]
```

Takeover always creates a new SyncRun. A terminal run never becomes active again.

### Side-effect rules

| Operation | Current Event grant | Matching owner token | Tickera request allowed |
|-----------|---------------------|----------------------|--------------------------|
| Claim new run | Required | New token created | No |
| Renew lease or heartbeat | Required | Required | No |
| Progress or checkpoint | Required | Required | No |
| Pause, resume, or user cancel | Required | Required | No |
| Dispatch a Tickera request | Required | Required | One checked request |
| Retry | Required | Required | Only after fresh checks |
| Successful completion | Required | Required | No |
| Failure while authorized | Required | Required | No |
| Authority-revoked cleanup | Not required | Required | No |
| Worker-crash cleanup | Not required | Required when owner is alive; otherwise recovery authority | No |
| Expired-run recovery | Not required | System locks and checks the exact expired run | No |
| Authorized takeover | Required | New token created | Only after commit and fresh request checks |

No current grant removes permission to start new work. It does not remove the system's duty to clean up the exact run that already started.

### Security and performance invariants

Freeze:

```text
NO NEW TICKERA REQUEST AFTER GRANT REVOCATION
NO NEW TICKERA REQUEST AFTER OWNER LOSS
NO STALE OWNER WRITE
NO EVENT-ID-ONLY ACTIVE-RUN CLEANUP
NO OLD RUN CLEARING NEW RUN HOT STATE
NO TWO ACTIVE RUNS FOR ONE EVENT
PAUSED RUN COUNTS AS ACTIVE
NO TERMINAL RUN REACTIVATION
NO EVENT STUCK SYNCING AFTER EXPIRED-RUN RECOVERY
NO ACTIVE SYNCRUN LEFT AFTER TERMINAL CLEANUP
NO LONG DATABASE LOCK ACROSS TICKERA IO
NO REDIS OR CACHEX OWNERSHIP AUTHORITY
NO OWNERSHIP READ FROM A REPLICA
```

Postgres stores durable ownership. `SyncState` holds hot runtime state only. Do not add Redis or Cachex. Keep transactions short, use the primary database for ownership, use bounded indexed recovery scans, and do not hold a database lock or connection across Tickera I/O. SyncRun coordination volume follows administrative sync activity, not attendee request volume.

### Future implementation boundary and sequence

The SyncRun implementation is separate from PR #514. The future reviewed file set may include:

```text
lib/fastcheck/events/sync_run.ex
lib/fastcheck/events/sync.ex
lib/fastcheck/events/sync_log.ex
lib/fastcheck/events/sync_state.ex
lib/fastcheck/events.ex
lib/fastcheck/events/sync_run_recovery_worker.ex
one migration
focused sync/run tests
```

The exact file set must be reviewed during implementation planning. Do not add these files in the authority PR. PR #514 remains blocked until the dedicated ownership implementation merges and passes post-merge CI.

Future implementation slices are:

```text
R0 schema, indexes, constraints, and SyncRun ownership primitives
R1 owner-scoped SyncState mirror
R2 atomic claim, control, and terminalization
R3 per-request Tickera authority and ownership checks, plus retries
R4 lease heartbeat, bounded recovery, and authorized takeover
R5 integration, concurrency, and security regression tests
R6 merge/closure verification, then unblock PR #514
```

R0–R6 must not mix in B2, B3, or B4 work. Programme order is:

```text
v1.3 authority freeze
→ dedicated SyncRun ownership implementation
→ review and merge
→ post-merge CI
→ rebase PR #514
→ finish the stale-identity creation correction
→ final B1 review and merge
→ B2 → B3 → B4 → B5
```

Until that sequence reaches the B1 rebase gate:

```text
PR_514_RESUME_AUTHORIZED=NO
B2_AUTHORIZED=NO
B3_AUTHORIZED=NO
B4_AUTHORIZED=NO
```

### Required future test matrix

Existing tests that expect an Event to remain `syncing` after a terminal sync failure must be identified and updated to the v1.3 terminal Event and SyncRun contract. Do not update those tests in the authority PR.

The R0–R6 implementation must test:

- Two concurrent claims yield exactly one active run; a paused run blocks a second claim.
- Claim plus Event transition rolls back atomically. Terminalization plus Event transition also rolls back atomically.
- Owner-token mismatch causes zero durable and hot-state writes. An old worker cannot update progress, clear newer `SyncState`, or terminalize a newer run after takeover.
- Only the live owner renews a lease. An expired owner cannot renew. Expired runs are recovered, and recovery issues zero Tickera calls.
- Authorized takeover creates a new run ID and token.
- Revocation before first request yields zero Tickera calls. Revocation between pages starts no next request. Revocation during a request permits that request to finish but discards its response before domain writes. Revocation before retry leaves retry count unchanged and starts no request.
- A paused run revoked by authority terminalizes and clears matching state. A worker crash reaches terminal run state and Event `active`. A healthy worker may continue after LiveView exit. Worker plus LiveView failure reaches bounded lease recovery.
- User cancellation starts no later request or write. Archive racing cleanup never unarchives the Event.
- Authorized retries retain the same run ID and token. Completed, failed, and cancelled runs cannot renew or mutate.
- The active-row invariant holds under database concurrency.
- The original v1.2 revoked-sync terminal-safety regression passes using owner-safe cleanup.

### Implementation stop conditions

The future implementation must stop if any of these holds:

```text
Event ID alone is used as active-run cleanup ownership
force_reset_sync/2 is called blindly after revocation
SyncState Agent state is the only ownership authority
a database connection or lock spans Tickera I/O
more than one durable active run can exist per Event, including paused runs
an old owner can mutate or clear a newer run's SyncState
an old owner can dispatch another Tickera request after losing authority or ownership
an expired owner can renew itself
an expired run is reused for takeover
recovery starts or retries Tickera work
a terminal cleanup changes archived to active
implementation expands into B2, B3, or B4
P1-D or v1.2 creation authority changes
second operational SyncRun storage table becomes necessary
Redis or Cachex is required for ownership
paused runs cannot participate in active-run uniqueness
owner fencing cannot cover every active-run mutation
per-request Tickera dispatch cannot be guarded
a database connection or lock would span Tickera I/O
```

Any such condition requires a new authority review. The documentation freeze itself changes no production code, tests, schema, migration, or dependencies.

### SyncLog identity and audit lifecycle

The existing `sync_logs.id` remains the database primary key. Persist the existing logical-run UUID as `sync_logs.sync_run_id`; do not use the numeric primary key as the run ID or add another run-ID column or table. One row represents one logical SyncRun. Authorized retries remain attempts within that row and retain the same `sync_run_id` and owner token. Pause and cancellation must update the durable row rather than only the Agent mirror.

The claim transaction must insert the `sync_logs` row successfully before it changes Event status or commits ownership. If insertion or any other claim write fails, roll back the entire claim. Do not continue with a missing log ID, a nullable run ID, or an untracked Tickera operation. A failed claim produces zero external requests.

Use the Postgres clock for run-owned timestamps. Set `sync_logs.started_at` and `events.sync_started_at` as part of claim. On every terminal state, set `sync_logs.completed_at`, duration, terminal status, and a safe error/reason value in the same owner-checked terminal transaction. Set `events.sync_completed_at` only after successful completion. Failure, cancellation, revocation, and lease expiry must not mark a run as successfully completed. Do not store attendee PII, credentials, secrets, or unredacted Tickera response bodies in run error fields or logs.

The run row remains an audit record after terminalization. Do not delete or reuse it during takeover. A retry does not create another row. If implementation needs a durable attempt count, it must add and document a specific field in its implementation plan; it must not overload the run ID or owner token.

### Terminalization and recovery fencing details

The normal terminalization path locks the Event first, then matches and locks the `sync_logs` row by `sync_run_id`, `owner_token`, and expected active status. The recovery path additionally rechecks `lease_expires_at <= database_now` in the same transaction. If a heartbeat renewed the lease first, recovery skips the row. If recovery terminalized first, a later heartbeat sees terminal status and is stale. Both paths update the Event only when the locked Event still has `status=syncing`.

After the durable terminal transaction commits, hot-state cleanup matches Event ID, `sync_run_id`, and owner token. If the mirror is already absent, cleanup is complete. If it contains another run or token, leave it untouched. Event cache invalidation follows the committed status change and is not evidence of ownership.
