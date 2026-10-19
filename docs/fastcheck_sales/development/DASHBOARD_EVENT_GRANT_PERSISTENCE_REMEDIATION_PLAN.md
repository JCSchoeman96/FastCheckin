# Dashboard Event-grant persistence remediation plan

| Field | Value |
|---|---|
| Plan ID | `DASHBOARD-EVENT-GRANT-PERSISTENCE-REMEDIATION` |
| Version | 1.3 |
| Status | Active governing authority. Gates A, B, and C implementation are accepted on current main. **Gate C implementation:** COMPLETE. **Gate C closure reconciliation (C3-B):** IN PROGRESS pending review, merge, and post-merge verification of this document update. **Gate D authorization:** NO. **Gate E authorization:** NO. |
| Accepted planning base | `SHA=87d2ed511e4e2fd135eb7a6bdd6c899d52d64b6b`, `TREE=68aef92f6eac17a46fb41419b6bb4fe8859f5578` |
| Related frozen authorities | `docs/fastcheck_sales/development/BROWSERAUTH_EVENT_ISOLATION_REMEDIATION_PLAN.md`, version 1.4; `docs/fastcheck_sales/feature_packs/0057_P1-D_event-scoped-sales-dashboard-authorization/pack.json` (merged as PR #491) |
| Implementation authorization | Gates A, B, and C implementation were separately authorized, reviewed, and merged. Gate D and Gate E are not authorized. |
| Tracking | `FastCheckin-qb8j` remains the programme tracking identifier. Gate C formal programme closure is pending C3-B document reconciliation merge and post-merge verification. |

## Revision history

- `1.3` reconciles programme-state metadata for accepted Gates B (programme), C1, C2, and C3-A implementation on main. It does not change the frozen technical contract or authorize Gate D or Gate E.
- `1.2` reconciles programme-state metadata only. It does not change the frozen technical contract.
- `1.1` entered as a proposed authority supersession. That supersession became effective when v1.1 merged.

## 1. Problem statement and production evidence

Production validation confirmed that Event creation, full attendee sync, the browser scanner, and a real check-in work. Event 24 was created, synced, scanned, and used for a successful check-in.

Gate C is implemented on current main. Dashboard Event creation uses a server-generated `dashboard_creation_token`, revalidates the current trusted identity and `DASHBOARD_EVENT_CREATION_ENABLED`, performs Tickera and attribute preparation outside the PostgreSQL transaction, then atomically inserts the Event and the creator's active `DashboardEventGrant`. After commit, the creator's dashboard refreshes and the Event is immediately visible and operable. Full Sync remains manual. WhatsApp Sales enablement remains manual.

The pre–Gate C operator workflow is obsolete for new dashboard-created Events:

```text
Create Event
→ CREATED_PENDING_SERVER_GRANT
→ edit DASHBOARD_ALLOWED_EVENT_IDS in Railway
→ redeploy production
→ manage or sync the Event
```

That workflow applied before Gates C1, C2, and C3-A merged. It is not the current creation model. `DASHBOARD_ALLOWED_EVENT_IDS` remains bootstrap, emergency, and backwards-compatible authority for configured Event IDs; it is not required to grant a newly dashboard-created Event to its creator.

## 2. Authority hierarchy

The frozen BrowserAuth version 1.4 document and merged P1-D feature pack remain historical records. The v1.1 authority supersession is active on current main. It supersedes only the BrowserAuth config-only Event-authority rules, prohibition on durable application-owned Event grants, and post-creation pending-grant rule, plus the specific P1-D grant-source and lookup prohibitions identified below. It does not supersede the remaining P1-D Sales security or business contracts.

All BrowserAuth and P1-D Sales surfaces that authorize dashboard Event operations share one effective Event-authority rule through `FastCheck.Sales.DashboardAccess`:

```text
verified server dashboard identity
        +
(
  configured bootstrap Event grant
  OR
  active durable server-owned Postgres Event grant
)
```

There is no config-only Sales exception and no separate BrowserAuth-versus-Sales grant resolution. Gate A and Gate B implementation was separately authorized and merged under separate approvals.

This document does not authorize code changes by itself. The v1.1 merge established the authority contract; Gates A, B, and C were later authorized, implemented, reviewed, and merged under separate approvals. Gate C programme closure completes when C3-B document reconciliation is reviewed, merged, and post-merge verified. Gates D and E each require separate authorization, review, merge, and successful post-merge CI before that gate starts.

## 3. Superseded BrowserAuth and P1-D clauses

The v1.1 authority supersession replaced these clauses only for their effect on BrowserAuth Event grants:

1. Version 1.4 §1 froze `EXISTING_EVENT_AUTHORITY=DASHBOARD_ALLOWED_EVENT_IDS` as the sole source for existing Events. The v1.1 supersession replaced it with the union authority in §5 of this document.
2. Version 1.4 §1 forbade a DB permission table and a per-row permission query as an authority source. The v1.1 supersession replaced that prohibition with the server-owned Postgres grant resource and indexed queries in §§6, 7, 13, 14, and 16 here.
3. Version 1.4 creation rules froze `CREATE_AUTO_GRANT=NO` and `EVENT_CREATED → CREATED_PENDING_SERVER_GRANT`. The authority contract in §10 specified the atomic Event-plus-creator-grant behavior for Gate C; that behavior is implemented and accepted on current main (Gates C1, C2, and C3-A).
4. The v1.1 supersession also replaced repeated config-only prohibitions that implement the same decision, including the matching implementation stop condition, the success criterion that excludes a permission DB or grant index, and version 1.4 §14's statement that no new permission table is authorized. Redis permission authority remains prohibited.
5. Version 1.4's interpretation of an empty configured ID list as the complete effective grant set was superseded only for grant resolution: an empty configured list still denies access unless an active durable grant exists. If the union is empty, Event data queries remain empty and fail closed.

The prohibition on adding a second configuration allowlist remains in force. The only grant sources are the existing bootstrap configuration and the durable grant resource defined here.

For the P1-D authority at `docs/fastcheck_sales/feature_packs/0057_P1-D_event-scoped-sales-dashboard-authorization/pack.json`, supersede only these grant-source decisions, and only insofar as they prohibit the durable server-owned grant mechanism authorized here:

1. `authority.configuration = DASHBOARD_ALLOWED_EVENT_IDS` as the exclusive Event-grant source. The effective source becomes the configured bootstrap grant OR an active durable grant for the verified dashboard identity and Event.
2. `performance.permission_database = false` as a prohibition on using the durable grant table as an authority source.
3. `performance.per_row_grant_lookup = false` as a prohibition on the bounded exact indexed lookup required by this authority.

No other P1-D clause is superseded. In particular, its authenticated identity source, forbidden browser and LiveView authority sources, Event ownership filters, fail-closed cross-Event behavior, and payment, refund, revocation, and inventory semantics remain authoritative. Its ban on Redis permission authority and per-Event query loops also remains in force.

Within version 1.4 §2, only the config-only result of `allowed_event_ids/1` and `event_granted?/2` is superseded. `FastCheck.Sales.DashboardAccess`, its current-identity verification, and its role as the compatibility-facing authorization boundary remain authoritative. Extend its result to the union authority without renaming the module or starting a broad namespace refactor.

## 4. Preserved BrowserAuth and P1-D invariants

These version 1.4 and PR #513/#514 invariants remain authoritative:

- Authentication is not authorization.
- Knowing an Event ID grants nothing.
- BrowserAuth has no global all-Event authority and must not restore `Events.list_events()` as an authorization shortcut.
- The browser, LiveView assigns, session data, request parameters, and caller-supplied `allowed_event_ids` cannot grant Event access.
- For P1-D Sales surfaces, the authenticated dashboard identity remains the identity source. Browser parameters, LiveView state, a requested Event or record, and a loaded Order or TicketIssue are not authority.
- There is no implicit all-Events fallback. Required Event-ownership filters remain in place, and rejected cross-Event operations fail closed without side effects.
- Existing payment, refund, revocation, and inventory semantics remain unchanged.
- P1-D Sales dashboards, refunds and revocations, ticket PDFs, checkout and offers, Event overview, WhatsApp controls, and related covered surfaces use the same `DashboardAccess` grant-source rule; none retains a config-only exception.
- BrowserAuth continues to identify the current trusted dashboard username from server configuration. No Users or Organizations system is introduced.
- Every Event-owned operation resolves current authority at its request boundary. A stale LiveView socket cannot keep a grant after revocation.
- Existing router authentication middleware and the route boundaries in version 1.4 remain in force.
- SyncRun ownership remains operational coordination state, not an authorization source. Existing `SyncAuthorityGuard` checks remain required for dashboard and scanner callers.
- No Redis permission authority is allowed.
- Event creation still requires the current trusted dashboard identity and `DASHBOARD_EVENT_CREATION_ENABLED=true`.
- Event creation never starts Full Sync automatically. The operator uses the existing manual Full Sync control after creation.
- Event creation never enables WhatsApp Sales automatically.
- Tickera attendee retrieval is not part of Event-creation input resolution.
- Tickera credential and Event-metadata requests stay outside a PostgreSQL transaction.
- No Tickera keys, scanner passwords, or other secrets are logged.
- The `/scanner/:event_id` ScannerAuth portal and mobile JWT authorization contracts remain unchanged.

## 5. Effective Event authority

Freeze the effective rule as:

```text
effective_event_authority(identity, event_id) =
  event_id ∈ server_configured_DASHBOARD_ALLOWED_EVENT_IDS
  OR
  active durable DashboardEventGrant exists for
    verified_dashboard_identity(identity) + event_id
```

`DASHBOARD_ALLOWED_EVENT_IDS` remains supported as bootstrap authority, emergency authority, and backwards-compatible production configuration. Dashboard Event creation on current main atomically grants the creator an active durable grant in the same transaction as the Event (§10). Configured IDs are not required for creator access to a newly dashboard-created Event.

Configured and durable grants are additive. A configured ID plus a revoked DB grant remains authorized by configuration. A DB revocation must never report that effective Event access was removed while the Event ID remains configured. A revoked DB grant denies access only when no configured grant also applies.

## 6. Domain and resource map

| Resource or boundary | Responsibility in this plan |
|---|---|
| `FastCheck.Access.DashboardEventGrant` | Gate A implemented the durable grant schema and focused grant operations. The resource belongs to an Event and stores active or revoked grant history. Its technical contract remains as defined in this document. |
| `FastCheck.Sales.DashboardAccess` | Existing compatibility-facing authorization boundary. Verify the current trusted identity, resolve configured plus active DB grants, and expose current allowed IDs and exact Event checks to existing callers. Keep the namespace and caller-facing API stable where practical. |
| `FastCheck.Events.Event` | Existing Event plus a server-generated creation idempotency token for dashboard-created Events. Retain grants by restrictive foreign key. |
| `FastCheck.Events` creation command | Resolve Tickera inputs before the transaction, then create the Event and creator grant atomically. Own replay handling for the creation token. |
| `FastCheckWeb.Plugs.BrowserAuth` and router | Continue authenticating the dashboard identity and wrapping every protected browser route. They do not accept grant data from the browser. |
| `FastCheckWeb.DashboardLive` | List only Events in the current effective grant set, create through the authorized command, refresh the dashboard after commit, and leave Full Sync manual. |
| Event-owned browser operations | Dashboard actions, exports, `ScannerLive`, `OccupancyLive`, and protected `handle_info` work call the existing authorization boundary at each request. |
| `FastCheckWeb.SyncAuthorityGuard` and `FastCheck.Events.SyncRunner` | Preserve the existing dashboard and ScannerAuth synchronization guards. A durable SyncRun does not grant Event access. |
| Postgres | Durable source for grant rows and uniqueness. Authorization reads use the primary database. |
| Existing Event caches and PubSub | Presentation and data-cache mechanisms only. They never decide authorization. Refresh or broadcast only after the transaction commits. |

The exact implementation file list is not frozen beyond the new resource, the existing compatibility boundary, Event creation, migration, affected browser callers, and their tests. Do not use this plan to justify unrelated refactoring.

## 7. Grant model and lifecycle

The required grant attributes are:

| Field | Meaning |
|---|---|
| `id` | Durable row identifier. |
| `dashboard_identity` | Exact verified server-configured dashboard username. |
| `event_id` | Event foreign key. |
| `state` | `active` or `revoked`. |
| `granted_at` | Time the grant became active. |
| `revoked_at` | Null while active; set when revoked. |
| `granted_by` | Verified server identity that issued the grant. Never accept this from the browser. |
| `lock_version` | Optimistic concurrency version for transitions. |
| `inserted_at`, `updated_at` | Persistence timestamps. |

Additional fields are not required by this authority. Do not add a grant-level creation request ID.

```text
active
  └── server-authorized revoke → revoked (terminal for this row)

revoked
  └── no transition back to active
      regrant → insert a new active row
```

The database must enforce valid states, consistent `revoked_at` values, and at most one active row for an identity/Event pair. Revoke commands take a grant selector only; they resolve the operator identity from the verified server context. They never accept a customer-supplied identity or grantor.

## 8. Grant transition guards and side effects

Grant creation is allowed only from a trusted server operation. Dashboard Event creation derives `dashboard_identity` and `granted_by` from the identity revalidated by `DashboardAccess`. The browser cannot request a grant for an unrelated Event.

Revocation is server-authorized. A conditional state transition or row lock must prevent two concurrent revocations from reopening or overwriting a terminal row. A repeated revoke is idempotent or returns a stable already-revoked result. A regrant inserts a new row and relies on the active uniqueness constraint to handle duplicate attempts.

When two grant attempts race, the unique active identity/Event constraint is the concurrency arbiter. The losing attempt re-reads the committed row and returns the existing active grant if one exists. It never changes a revoked row back to active.

Any authorization cache invalidation or optional PubSub notification happens after commit. A notification may contain grant and Event IDs only. Each receiving LiveView resolves current authority before it refreshes or handles Event-owned work.

## 9. Grant terminal states and effective access

`revoked` is terminal for a grant row. There is no expiry or TTL. A later grant inserts a distinct row.

The Event's effective access is the union of configuration and active rows, not a copy of the latest grant row. Therefore:

```text
configured Event ID + revoked DB grant = authorized
no configured Event ID + revoked DB grant = denied
no configured Event ID + active DB grant = authorized
neither source grants Event ID = denied
```

## 10. Event creation state machine and transaction contract

```text
server renders create form with server-generated creation token
  ↓ submit
revalidate current trusted dashboard identity
  AND DASHBOARD_EVENT_CREATION_ENABLED=true
  ↓
if this token already committed, revalidate current Event authority and return that Event
  ↓ otherwise
validate Tickera credentials and fetch Event metadata outside transaction
  ↓
prepare normalized and encrypted Event attributes outside transaction
  ↓
revalidate current identity and creation capability
  ↓
BEGIN PostgreSQL transaction
  ↓
insert Event with its creation token
  ↓
insert creator's active DashboardEventGrant
  ↓
COMMIT
  ↓
invalidate rebuildable local Event caches and refresh the dashboard
  ↓
Event is immediately operable by its creator
  ↓
operator may manually start Full Sync
```

The Event and its creator grant form one atomic commit. A dashboard-created Event must not commit without the active creator grant.

| Outcome | Required result |
|---|---|
| Current identity or creation flag fails | Deny before Tickera, Event write, or grant write. |
| Tickera credential or metadata request fails | Create neither Event nor grant. |
| Event insert fails | Grant is not inserted; transaction contains no committed Event. |
| Grant insert fails | Roll back the Event and grant transaction. |
| Transaction commits | Refresh the dashboard and show the normal manual Full Sync control. |
| Post-commit cache or UI refresh fails | Keep the committed Event and grant. Retry or later refresh reads durable state; do not create a compensating Event or grant. |

No transaction may contain a Tickera, WhatsApp, PubSub, cache-network, or other external request. Full Sync and WhatsApp Sales remain separate operator-controlled operations.

## 11. Event-creation idempotency decision

The Event-creation command boundary owns duplicate-submit semantics. Persist a nullable, server-generated `dashboard_creation_token` on the Event and enforce its uniqueness in Postgres. The token is generated by the server for one logical create form submission and reused for retries of that submission. A new intentional Event creation receives a new token.

The token is opaque, generated by the server, and cryptographically strong, with at least 128 bits of entropy (for example, UUIDv4-equivalent entropy). The server renders it with the create form and the browser may echo it on submission. Reject missing or malformed token values before any Tickera read or database mutation. A token is an idempotency key only: it is not an identity, grant, capability, or authorization input. Arbitrary or malformed token values cannot change the verified identity, grant target, or authorization outcome. Every create or replay request still revalidates the current trusted identity and creation kill switch. Before returning an existing Event for a committed token, the application also resolves current Event authority for that identity and Event.

One server-generated token applies to one logical create attempt. Validation or create failure before commit preserves the same token for retry of that attempt. Cancel or successful commit clears the token from the create flow; the next intentional create receives a new token. There is no token TTL and no Redis, ETS, or Cachex token authority.

Concurrent requests with the same token may both finish their bounded Tickera reads, but the database uniqueness rule permits one Event commit. A losing request exits its failed transaction before recovering the Event associated with that token. It returns the existing logical result only after current authorization checks. It does not insert a second grant. If the first transaction rolls back, the same token can be retried and may commit once.

The token defines one logical create operation. If a committed token is submitted with changed form values, return the original Event after authorization checks and ignore the changed values. A deliberate new create operation uses a new server-generated token. If concurrent submissions with the same token carry different values before either commits, the first transaction to commit defines the result; the other request recovers that result. This avoids a second Event without adding a payload fingerprint or a separate request table.

This Event field is smaller than a separate creation-request resource for the required guarantee: deduplicate a logical form submission, recover a completed result after a lost response, and leave failed pre-commit attempts retryable. A committed-token preflight lookup avoids repeating Tickera reads on ordinary retries. Concurrent requests that both miss that lookup may both finish their bounded Tickera reads, but the database uniqueness rule permits one Event commit. Do not add a request table or a `creation_request_id` to `DashboardEventGrant` without new evidence that Event-row uniqueness cannot meet these guarantees.

## 12. Event deletion and grant-history policy

Choose policy A: grant rows are retained security history, so permanent Event deletion is blocked while any grant row references the Event, including revoked rows.

The grant foreign key uses restrictive deletion. Do not use `ON DELETE CASCADE`. Extend `ArchivedEventRemoval` dependency accounting to report grant rows as blockers, while retaining the restrictive foreign key as the race-safe integrity backstop. Archiving remains available. Permanent deletion requires no grant-history references; this plan does not authorize an implicit purge, detach, or tombstone process.

This matches the existing `ArchivedEventRemoval` behavior, which locks the Event, checks durable dependencies, and treats restrictive foreign-key violations as integrity conflicts. It preserves grant history with the same fail-closed approach used for scan, sync, and Sales records.

## 13. Exact authority-resolution algorithm

`FastCheck.Sales.DashboardAccess` remains the common authority boundary for existing BrowserAuth and P1-D Sales callers:

1. Receive the identity from the authenticated server request context. Do not read identity or `allowed_event_ids` from browser parameters, session grants, or a caller actor's grant list.
2. Revalidate the identity against the current trusted dashboard configuration. If it is no longer the configured trusted identity, return unauthorized without querying grants.
3. Read the current server-configured `DASHBOARD_ALLOWED_EVENT_IDS` set from runtime configuration.
4. For `allowed_event_ids(identity)`, issue one indexed Postgres query for `event_id` where `dashboard_identity` equals the verified username and `state='active'`. Return the sorted unique union of those IDs and configured IDs. If the durable query fails, retain only configured IDs; never manufacture DB authority.
5. For `event_granted?(identity, event_id)`, reject invalid IDs and unauthorized identities. Return true immediately if the Event ID is configured. Otherwise issue an exact indexed active-grant existence query for the verified username and Event ID. A DB error denies the durable-only grant.
6. Pass the resulting IDs into `Events.list_events_by_ids/1` or an equivalently scoped query. An empty union returns an empty result without a global Event list, aggregate, cache population, or rollup query.

The runtime-configured username is compared using its existing exact identity semantics. A DB query failure may reduce access to the configured subset; it must never broaden access. Use the primary database so a just-committed grant and a committed revocation are visible to the next authority check.

## 14. Required migration and index design

Add a durable grant table with the required fields in §7 and an Event foreign key using restrictive deletion. Use database constraints for the state vocabulary and the `state`/`revoked_at` relationship. Keep legacy Events and current runtime configuration valid without backfill.

Freeze these indexes conceptually:

| Index | Purpose |
|---|---|
| B-tree on `(dashboard_identity, state, event_id)` | One identity-scoped lookup for active Event IDs; supports the identity/state filter without scanning unrelated grants. |
| Partial unique B-tree on `(dashboard_identity, event_id) WHERE state='active'` | Enforce one active grant per identity/Event pair and serve exact active existence checks. |
| B-tree on `event_id` | Reverse lookup for Event deletion checks and foreign-key maintenance. |
| Partial unique B-tree on `dashboard_creation_token` where non-null | Enforce one committed Event per server-issued create token while leaving non-dashboard Event inserts compatible. |

Use the exact partial-index predicates in application queries so Postgres can use the indexes. Do not use a table scan, load grant schemas one row at a time, or issue one durable query per Event in a dashboard list.

## 15. Security and stale-socket review

- `DashboardAccess` revalidates the current trusted identity at every protected request boundary. A mount-time actor or `allowed_event_ids` snapshot is not authorization.
- Every Event action and every `handle_info` that reads, mutates, exports, queues, decrypts, or discloses Event-owned data resolves current effective authority for the effective Event ID before work begins.
- A stale connected LiveView receives denial on its next protected operation after a revocation commits, even if it missed PubSub. PubSub refreshes presentation only.
- A request whose fresh check passed before a concurrent revocation is already in flight. Long-running work must retain the existing request/side-effect checks, including `SyncAuthorityGuard` before sync work. Checks performed after a revocation commit deny unless configuration still grants the Event.
- No Event ID knowledge, hidden form value, creation token, LiveView assign, session value, or caller-supplied grant list creates authority.
- Revoke and grant identities come from the verified server context. No public route accepts a dashboard identity or grantor.
- Configured IDs stay additive, so a DB revoke cannot claim effective revocation while configuration still includes that Event.
- Preserve route authentication middleware, export safe-denial behavior, browser scanner isolation, occupancy isolation, and existing ScannerAuth/mobile scope.
- Do not log Tickera credentials, scanner passwords, raw grant tokens, or unnecessary dashboard identity data.

## 16. Performance and scaling review

Postgres is the durable source for active grants. Runtime configuration remains in process memory for bootstrap IDs. Redis has no permission role. No authorization table scan or polling is allowed.

Dashboard listing uses one identity-scoped indexed query for active Event IDs plus the in-memory configured set. A single Event operation uses a short-circuit configured membership check or one exact indexed existence query. Query result size is limited to the grants for the verified identity. Normal Event authorization must remain below 100 ms under production-like load.

The MVP requires no grant cache. If later measurements justify one, it must be rebuildable, short-lived, invalidated after grant/revoke commit, and unable to preserve positive authority after a revocation. PubSub may carry grant/Event IDs after commit; recipients still query current authority. No sensitive identity data is needed in that broadcast.

## 17. Migration, compatibility, and rollback contract

- Existing `DASHBOARD_ALLOWED_EVENT_IDS` works immediately after deployment. No migration of configured IDs into Postgres is required.
- Event 24 and every other currently configured Event ID remain accessible through the bootstrap authority.
- Durable grants add authority; they do not replace or rewrite configured IDs.
- Deployment must not temporarily broaden visibility. New code resolves only the configured set plus active grants for the verified identity.
- Schema expansion is additive. Do not drop or rewrite config grants during rollout or rollback.
- If application rollback returns to code that only reads configured IDs, those configured grants continue working. Do not claim that older config-only code honors DB-only grants. Keep grant rows and migrations intact during rollback; any emergency access for older code uses the existing bootstrap configuration path.
- No production data mutation is part of this authority document or its PR.

## 18. Required test coverage

Before the relevant implementation gate can close, tests must prove:

1. A configured bootstrap grant remains accepted immediately after deployment.
2. An active DB grant is accepted for the verified identity.
3. A revoked DB grant is denied when configuration does not grant the Event.
4. An unrelated identity is denied, even when it knows the Event ID.
5. A configured grant plus a revoked DB row remains authorized.
6. Browser-supplied `allowed_event_ids`, identity, or grantor cannot create authority.
7. A dashboard-created Event receives one active creator grant in the same transaction.
8. Event insert failure creates no grant, and grant insert failure rolls back the Event.
9. Tickera credential or metadata failure creates neither Event nor grant.
10. A stale socket is denied after revocation on its next Event operation without relying on PubSub.
11. Concurrent duplicate submissions with the same server-issued token create one Event and one active grant; a retry recovers the committed Event after current authority checks.
12. Reusing a committed token with changed form values returns the original authorized Event and creates no second Event.
13. A regrant inserts a new active row and does not mutate revoked history.
14. The newly created Event appears in the creator's dashboard immediately and exposes the normal manual Full Sync control without a Railway edit or deployment.
15. Full Sync does not start automatically, and WhatsApp Sales does not enable automatically.
16. Grant history blocks permanent Event deletion, including when the grant is revoked.
17. Existing Event and scanner isolation remains intact, including Event-ID guessing denial and manual scanner check-in.
18. PR #513/#514 BrowserAuth, export, dashboard, scanner, occupancy, SyncAuthorityGuard, SyncRun, and ScannerAuth regression suites remain green.
19. P1-D Sales dashboard, refund and revocation, ticket PDF, checkout, offer, Event overview, WhatsApp control, and other covered operations all use the shared `DashboardAccess` authority. Cross-Event operations remain rejected and fail closed; existing payment, refund, revocation, and inventory behavior is unchanged.

Place tests beside the existing suites in `test/fastcheck/sales/dashboard_access_test.exs`, `test/fastcheck_web/live/dashboard_live_test.exs`, `test/fastcheck/integration/browserauth_event_isolation_test.exs`, `test/fastcheck/events/archived_event_removal_test.exs`, and the relevant sync authority tests. Update an existing test file only when the behavior belongs to that suite.

## 19. Implementation gates

Each gate requires review, merge, successful post-merge CI, and explicit authorization before the next gate starts. Gate 0, Gate A, Gate B, and Gate C implementation are accepted on current main. Gate C formal programme closure is pending C3-B document reconciliation. Gates D and E are not authorized.

| Gate | Current state | High-level scope | Completion evidence |
|---|---|---|---|
| Gate 0 | ACCEPTED / MERGED | This authority document only. | Docs-only PR merged; no code or production data changed. |
| Gate A | ACCEPTED / MERGED AS PR #539, merge SHA `830eb32b5dd0536351549866ffa87cae26aefd9b` | Add the Postgres resource, Event relationship, constraints, and indexed bounded grant queries. | Schema and query tests prove terminal state, uniqueness, restrictive FK, and index-backed lookup behavior. |
| Gate B | ACCEPTED / MERGED AS PR #540, merge SHA `d29f337df1bfafe479f02ea4d1f6f050bcad9644`; programme authority reconciliation PR #543, merge SHA `d45e33bed5a5f9bdf7713c61bbda33d21a8e1b30` | Extend `DashboardAccess` to resolve configured IDs plus active DB grants for BrowserAuth and P1-D Sales callers through the same boundary. Keep current identity revalidation, Event-ownership filters, and query-scoped dashboard lists. | Bootstrap, active, revoked, unrelated-identity, caller-forgery, stale-socket, and existing PR #513/#514 tests pass. P1-D Sales dashboards, refunds/revocations, PDFs, checkout/offers, Event overview, and WhatsApp controls prove the same union authority, fail-closed cross-Event behavior, and unchanged payment/refund/revocation/inventory semantics. |
| Gate C1 | ACCEPTED / MERGED AS PR #544, merge SHA `79b694650252a621f71479c1d7b3ada723c3d28f` | Persist nullable server-generated `dashboard_creation_token` on Event with partial unique index where non-null. | Token validation, uniqueness, and idempotency contract tests pass. |
| Gate C2 | ACCEPTED / MERGED AS PR #545, merge SHA `8b2c75187796bfd222db902fa75949290b4d0ce8` | Atomic Event-plus-creator-grant transaction; Tickera and preparation outside the transaction. | Rollback, Tickera failure, duplicate submission, and transaction-boundary tests pass. |
| Gate C3-A | ACCEPTED / MERGED AS PR #546, approved head SHA `57d2cbf229db601feab3d40d30e63ebf0afb7498`, merge SHA `87d2ed511e4e2fd135eb7a6bdd6c899d52d64b6b`, tree `68aef92f6eac17a46fb41419b6bb4fe8859f5578`; post-merge CI workflow run `39301897012` (`2317 tests, 0 failures, 4 skipped`) | Wire `DashboardLive` to the authorized creation command; immediate post-commit visibility and manual Full Sync only. | Dashboard creation integration, committed-token replay, immediate visibility, and manual-only Full Sync tests pass. |
| Gate C (programme) | **Implementation:** COMPLETE AND ACCEPTED. **Closure reconciliation (C3-B):** IN PROGRESS pending merge of this v1.3 update. | Gates C1, C2, and C3-A deliver §§10–11 on current main. | Evidence in Gate C1–C3-A rows; formal Gate C programme closure completes when C3-B is reviewed, merged, and post-merge verified. |
| Gate D | NOT AUTHORIZED | Add server-authorized revoke/regrant behavior and stale-socket regression coverage. | Revoked rows stay terminal; configuration remains additive; every protected operation resolves current authority. |
| Gate E | NOT AUTHORIZED | Production certification of `Create → immediately visible → manual Full Sync → Scanner → check-in` with no `DASHBOARD_ALLOWED_EVENT_IDS` edit for the new Event. | Reviewed production evidence, no isolation regression, and successful post-merge CI. |

No gate authorizes automatic Full Sync, WhatsApp Sales enablement, global Event access, or a broader authentication rewrite.

## 20. Explicit stop conditions

Stop and return to authority review if any of these conditions occurs:

- `STOP=MAIN_MOVED` if `origin/main` differs from the explicitly accepted base SHA or tree for the currently authorized gate or corrective task before work begins.
- `STOP=SECURITY_INVARIANT_WEAKENED` if BrowserAuth request-boundary revalidation, Event isolation, or stale-socket denial would be weakened.
- `STOP=GLOBAL_EVENT_ACCESS_REINTRODUCED` if implementation requires unscoped Event listing or global browser authority.
- `STOP=CALLER_SUPPLIED_GRANT_AUTHORITY` if identity, grantor, or Event authority comes from browser/session input.
- `STOP=REDIS_PERMISSION_AUTHORITY` if Redis is required to decide access.
- `STOP=EXTERNAL_CALL_INSIDE_DB_TRANSACTION` if Tickera or another external request must run inside the Event/grant transaction.
- `STOP=IDEMPOTENCY_OWNERSHIP_UNRESOLVED` if the Event-row creation token cannot enforce one committed Event per logical submission and recover a successful retry.
- `STOP=EVENT_DELETION_POLICY_UNRESOLVED` if restrictive grant-history retention cannot be reconciled with Event deletion.
- `STOP=UNAUTHORIZED_GATE_IMPLEMENTATION_STARTED` if code or migrations for Gate D or E are changed before that gate receives separate explicit authorization.

This v1.3 authority-state reconciliation records accepted Gate C implementation and proposes Gate C programme closure when C3-B is merged and post-merge verified. It does not authorize Gate D or Gate E. After opening this docs-only PR, stop for C3-B review. Do not start Gate D or Gate E without separate explicit authorization.
