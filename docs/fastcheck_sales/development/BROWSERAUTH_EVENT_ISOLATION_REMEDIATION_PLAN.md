# BrowserAuth Event-Isolation Remediation Plan

| Field | Value |
|-------|-------|
| **Plan ID** | BROWSERAUTH-EVENT-ISOLATION-REMEDIATION |
| **Plan version** | 1.1 |
| **Status** | FROZEN |
| **Scope** | Close the remaining P0 gap: general BrowserAuth surfaces that operate on Events must enforce server-owned per-Event authority (P1-D grant semantics) before reads, mutations, exports, scanner actions, occupancy, and secret reveal |
| **Authority** | This file is the **active contract** for BrowserAuth Event-isolation implementation (B0–B5). P1-D (`FastCheck.Sales.DashboardAccess` + Sales routes) is **accepted and frozen**; do not reopen P1-D behavior in this workstream. Launch/runbook policy docs are **out of scope** until implementation evidence exists. |
| **Accepted base** | `BASE_SHA=a56d2cc0e119ae84d1509e508486d19ee5e12663`, `BASE_TREE=2018bda825474a7cf04f67724c74028e10a036d9` |
| **Tracking** | `FastCheckin-v6u9` (Beads / `bd`; verified locally 2026-10-09) |
| **Last updated** | 2026-10-09 |
| **Change summary (1.1)** | Master-review corrections: preserve empty Event-grant semantics; freeze `DASHBOARD_EVENT_CREATION_ENABLED` parsing; require grant-scoped Event and attendee aggregate queries (no global `events:all` filter) |
| **Change summary (1.0)** | Initial authority freeze: existing-Event grants via `DASHBOARD_ALLOWED_EVENT_IDS`; creation via `DASHBOARD_EVENT_CREATION_ENABLED`; query-scoped dashboard list; decoupled create/sync; implementation slices B0–B5 |

### Revision log

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
EVENT_CREATION_AUTHORITY=DASHBOARD_EVENT_CREATION_ENABLED
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

### 4. Creation side effects

Creation permission authorizes **insert of the Event record only**.

A successful create **must not** automatically:

```text
append new Event ID to DASHBOARD_ALLOWED_EVENT_IDS
create browser/session Event grant
start full or incremental sync
enable WhatsApp Sales
reveal mobile/scanner secrets
subscribe to Event PubSub
perform Event-owned external API work
```

**Operational state after create:**

```text
CREATED_PENDING_SERVER_GRANT
```

The Event becomes ordinarily operable only when its ID is in `DASHBOARD_ALLOWED_EVENT_IDS` (config change + deploy/restart per existing ops procedure).

**Edge case:** If the new Event’s ID was **pre-listed** in `DASHBOARD_ALLOWED_EVENT_IDS`, later requests may treat it as granted—but **creation itself still must not auto-start sync**. Creation and synchronization are decoupled.

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
  DASHBOARD_EVENT_CREATION_ENABLED → may insert Event row only

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
CREATE_DISABLED
  → terminal: no Event row, no side effects

CREATE_ENABLED
  → EVENT_CREATED (DB row only)
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
| `DASHBOARD_EVENT_CREATION_ENABLED` | Allow `Events.create_event/1` from dashboard only | missing/blank → **false**; see frozen parser in §3 (`1`/`true`/`yes`/`on` vs `0`/`false`/`no`/`off`; other nonblank → boot error) |

```text
DASHBOARD_ALLOWED_EVENT_IDS_REQUIRED_IN_PROD=NO
```

---

## Route / action matrix (target behavior)

| Route / action | Auth pipeline | Event grant | Creation flag |
|----------------|---------------|-------------|---------------|
| `/`, `/dashboard` list | dashboard_auth | grant set scopes query | — |
| `create_event` | dashboard_auth | — | required |
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
| `Repo.insert/update/delete` on Event | grant or creation flag |
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
| Creation disabled | `create_event` denied; no row |
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

- flag false → no Event created
- flag true → Event row created
- success → no auto-sync, no auto-grant, no WhatsApp enable from create path

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
| **B1** | `DashboardLive` query-scoped mount/refresh; grant on all Event `handle_event`; creation policy; **remove create→sync coupling** | B0 |
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

## Current baseline evidence (accepted SHA)

Pointers for implementers rebasing to `a56d2cc0e119ae84d1509e508486d19ee5e12663`:

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
NEW EVENT CREATION → DASHBOARD_EVENT_CREATION_ENABLED only
NEW EVENT → no grant and no sync as side effect of creation
ROOT LIST → query-scoped by granted IDs
ALL LISTED ROUTES → grant before side effects
P1-D → unchanged behavior and tests
NO Redis / permission DB / new index for grants
```

---

## Plan-only PR gate

This document version `1.1` / `FROZEN` is the repository authority contract once merged to `main`. **No B0 implementation** until human merge gate on PR #512 completes.
