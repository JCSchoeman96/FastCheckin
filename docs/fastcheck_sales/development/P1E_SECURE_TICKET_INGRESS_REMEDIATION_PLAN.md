# P1-E Secure Ticket Ingress Remediation Plan

| Field | Value |
|-------|-------|
| **Plan ID** | P1E-SECURE-TICKET-INGRESS-REMEDIATION |
| **Plan version** | v1.5 |
| **Status** | FROZEN — ready for implementation review (plan-only; no code in this artifact) |
| **Scope** | Remediate P1-E ingress logging blocker by removing delivery bearer from HTTP request targets; browser ticket-session via one cookie + warm Redis HASH registry (not durable ticket authority) |
| **Authority** | This file is the **active contract** for P1-E implementation. `docs/fastcheck_sales/product/LAUNCH_SCOPE_RUNBOOK_REQUIREMENTS.md` remains the launch gate source for `INGRESS_REQUEST_LOGGING_SAFE`. On conflict, this plan defines *how* P1-E is satisfied; the runbook defines *when* the gate may clear. |
| **Accepted base** | `BASE_SHA=71462644f91d9c8132c0a5a4ac5df97e2c8acd81`, `BASE_TREE=56de18e69be5a5140b7bf9eb131ea4f49c9304ae` |
| **Last updated** | 2026-10-04 |
| **Change summary (v1.5)** | Monotonic `delivery_token_generation` on `TicketIssue` (migration); generation-aware Redis bind; stale exchange cannot overwrite newer generation. |
| **Change summary (v1.4)** | Atomic Redis session bind (HSET+EXPIRE) and compare-and-delete invalidation; Redis TIME + unique ZSET members for rate limits; trusted Cloudflare CIDR + `CF-Connecting-IP` rule. |
| **Change summary (v1.3)** | One `_fastcheck_ticket_session` cookie + Redis HASH registry (replaces per-ticket cookie fan-out); distributed Redis ZSET rate limits; trusted client-IP rules for new P1-E guards. |
| **Change summary (v1.2)** | Multi-ticket path-scoped signed cookie claims; ticket-specific view/PDF routes; `GET /t` bootstrap-only; separated exchange vs session-read rate limits. *(Per-ticket cookie fan-out **superseded** by v1.3.)* |
| **Change summary (v1.1)** | Two-stage production cutover; `P1E_LEGACY_INVENTORY_GATE`; conditional P1E-F; fingerprint v1; RawBodyReader; PR #494 distance (40). |
| **Change summary (v1)** | Initial fragment ingress contract. |

### Revision log

- `v1` — Initial security architecture contract after production ingress diagnostic (`RAILWAY_RAW_PATH_LOGGING=CONFIRMED`).
- `v1.1` — Production cutover sequencing; P1E-F gated on legacy cohort replacement; frozen generation fingerprint v1.
- `v1.2` — Multi-ticket routes `/t/view/:id`; reject global Phoenix session; cross-ticket fail-closed semantics. *(Cookie-per-ticket storage rejected in v1.3.)*
- `v1.3` — Replace per-ticket cookie fan-out with one browser ticket-session cookie + Redis HASH registry; freeze distributed Redis ZSET rate limiting and trusted client-IP rules.
- `v1.4` — Atomic Redis session binding/invalidation; distributed rate-limit clock/member semantics; trusted Cloudflare client-IP validation (CIDR-gated `CF-Connecting-IP`).
- `v1.5` — Freeze monotonic `delivery_token_generation` as durable token-generation ordering authority; generation-aware Redis bind prevents stale exchange overwrite.

---

## Problem statement

Production topology (evidence 2026-10-04):

```text
Browser → Cloudflare → Railway HTTP edge → FastCheck (Phoenix)
Host: https://scan.voelgoed.co.za
```

Accepted diagnostic:

```text
RAILWAY_RAW_PATH_LOGGING=CONFIRMED
INGRESS_REQUEST_LOGGING_SAFE=FAIL
P1E_INGRESS_BLOCKER=OPEN
```

Today, WhatsApp generates path links `GET /t/<delivery-token>`. Bearer appears in HTTP request targets at Cloudflare/Railway before Phoenix. Application log hardening (PR #494) cannot clear P1-E while bearers remain in request targets for the new flow.

### Multi-ticket domain fact

```text
initial_ticket_delivery = one TicketDeliveryIntent per TicketIssue
FastCheck.Sales.PurchaseLimits.max_tickets_per_order() = 50
```

A browser may hold **many concurrently valid** ticket links. Architecture must support **50 tickets** without cross-ticket artifact collision.

### Cookie-scale fact (v1.3)

RFC 6265 guarantees only a **minimum** cookie capacity per domain (~50 cookies); user agents may evict cookies. FastCheck already uses cookies (e.g. `_fastcheck_key`). v1.2’s **one cookie per accessed `TicketIssue`** can exceed standards-level minimums for a legitimate 50-ticket order.

```text
PER_TICKET_COOKIE_FANOUT=REJECTED (v1.2)
```

Stateless per-ticket cookies are **proven insufficient** at platform ceiling. v1.3 uses **one browser cookie** + **warm Redis HASH** (ephemeral bindings only; Postgres remains durable authority).

---

## Frozen security invariant

(Steady state after hard cutover — unchanged intent from v1.1/v1.2.)

Delivery bearer must not occur in HTTP path/query (new flow), Referer, redirects with bearer, logs, Sentry, telemetry, localStorage, sessionStorage, DB plaintext, or Redis keys/values.

Transient bearer only in: URL fragment, browser memory during exchange, `POST /t/session` body (`delivery_token`), process memory during validation.

```text
NO PLAINTEXT DELIVERY BEARER IN HTTP REQUEST TARGET.
```

Compatibility window: legacy `/t/:token` may still hit ingress with bearer; `INGRESS_REQUEST_LOGGING_SAFE=FAIL`.

---

## Current architecture (repository baseline)

| Layer | Behavior |
|-------|----------|
| **Link generation** | `... <> "/t/" <> token` |
| **Routes** | `GET /t/:token`, `GET /t/:token/pdf` |
| **Rate limit** | `secure_ticket_operation?` → `/t/` prefix; **local ETS** via PlugAttack; 5/min per IP |
| **Mobile shared limits** | Redis backend for some mobile routes only |
| **Client IP** | `get_peer_ip/1` uses first `X-Forwarded-For` value |

Pinned `plug_attack 0.4.3` provides ETS storage; **do not** depend on non-existent `PlugAttack.Storage.Redis` for P1-E.

---

## Target architecture (v1.3)

```text
WhatsApp → /t#<delivery-token>

Browser:
  Cookie: _fastcheck_ticket_session=<signed opaque browser_session_id>
          Path=/t; HttpOnly; SameSite=Lax; Secure (prod); no Max-Age

  GET /t                          bootstrap only
  POST /t/session                 exchange → atomic HSET+EXPIRE ticket:<id> → fingerprint
  GET /t/view/:ticket_issue_id    HGET + Postgres revalidation
  GET /t/view/:ticket_issue_id/pdf

Redis HASH (warm, idle TTL 24h):
  key: ticket-browser-session:<hash(session-id)>
  fields: ticket:<ticket_issue_id> → v1:<generation>:<delivery_generation_fingerprint>
```

**Preserved from v1.2:** routes, fragment URL, fingerprint v1 algorithm, multi-ticket isolation semantics, cross-ticket fail-closed, bootstrap-only `GET /t`.

**Rejected:** v1.0–v1.1 global `/t` + `/t/pdf`; v1.2 per-ticket `_fastcheck_ticket` cookie fan-out.

---

## Domain / resource map

| Component | Role |
|-----------|------|
| `lib/fastcheck/tickets/ticket_session.ex` (**new**) | Browser session id; Redis HASH registry; atomic bind/TTL; compare-and-delete; resolve → `ArtifactResolver` |
| `FastCheck.Tickets.DeliveryToken` | Unchanged |
| `FastCheck.Tickets.ArtifactResolver` | Same eligibility path for exchange and session resolve |
| `FastCheck.Sales.TicketPage` | HTML from validated registry entry + route id |
| `SecureTicket*` controllers | Bootstrap, exchange, view, PDF |
| `assets/js/secure_ticket_bootstrap.js` | Fragment → `POST /t/session` → `location.replace(/t/view/id)` |
| `SendWhatsAppTicketLinkWorker` | `"/t#" <> token` |
| **Redis** | WARM: ticket-browser-session HASH; WARM: secure-ticket rate-limit ZSETs |
| **Postgres** | COLD: `TicketIssue` + `delivery_token_generation`; `ArtifactResolver` |
| **Migration** | Add `TicketIssue.delivery_token_generation` (v1.5); no new table/index |

**Non-goals:** new DB table, durable ticket authority in Redis, `PlugAttack.Storage.Redis`, new dependencies for rate limiting.

---

## Durable delivery token generation (v1.5 — frozen)

Fingerprint v1 alone does not provide monotonic ordering under concurrent exchange. Add explicit lifecycle counter on `TicketIssue`:

```text
delivery_token_generation :integer
NOT NULL
default 0
minimum 0
```

Semantics:

```text
- identifies the currently authoritative delivery-token generation for one TicketIssue
- NOT a bearer, timestamp, ticket version, scanner version, or browser-session version
```

**Migration:** existing rows → `delivery_token_generation = 0` (valid for current hash). Next rotation → `1`, then `2`, … No historical reconstruction.

**Initial issuance:** first token may remain at generation `0`; do not increment merely because the first token exists. Counter advances on **rotation** away from initial generation.

**Rotation (`rotate_delivery_token_for_delivery` or equivalent)** must persist **one** atomic durable transition:

```text
delivery_token_hash       → new hash
delivery_token_expires_at → new expiry
delivery_token_generation → previous + 1
```

Forbidden:

```text
using delivery_token_expires_at, updated_at, or inserted_at as generation ordering
unprotected read-modify-write of generation in application code without DB atomicity
committing hash/expiry/generation independently
```

Require Ash/Postgres concurrency-safe increment (optimistic lock or equivalent). Concurrent rotations must not both persist the same resulting generation (`G0→G1` and `G0→G2`, not two `G1`).

If the chosen Ash action cannot prove this: **STOP** implementation; do not approximate with timestamps.

**Registry invalidation on rotation:** Postgres rotation is durable authority; Redis stale bindings are rejected/removed lazily on read; fresh exchange with `G+1` forward-only overwrites per bind rules. No PubSub; no distributed Redis↔Postgres transaction.

---

## Browser ticket-session model (v1.3 — frozen)

### One cookie

```text
Name:   _fastcheck_ticket_session
Path:   /t
```

Contains **only** a signed opaque `browser_session_id` (recommended: 32 random bytes, `Base.url_encode64(..., padding: false)`).

Signing namespace:

```text
ticket-browser-session:v1
```

Preferred: `Phoenix.Token` with `max_age: :infinity` for the opaque id (browser-session cookie lifetime + Redis idle TTL + Postgres authority define validity — not a second ticket TTL).

Cookie **must not** contain: delivery token, `delivery_token_hash`, fingerprint, ticket list, artifact, PII.

```text
MAX_TICKET_SESSION_COOKIES_PER_BROWSER=1
```

(independent of ticket count, orders, tabs)

### Redis HASH registry

Use existing `FastCheck.Redix` / `FastCheck.Redis.Namespace`. No new Redis client.

Redis key id (do not store raw session secret in key):

```text
session_id_hash = SHA-256("ticket-browser-session:v1:" <> browser_session_id)
namespaced key: ticket-browser-session:<session_id_hash>
```

Fields (generation binding):

```text
ticket:<ticket_issue_id> → v1:<generation>:<delivery_generation_fingerprint>
```

Compact deterministic encoding; semantic fields are generation + fingerprint v1. Never store in Redis: plaintext delivery token, raw `delivery_token_hash`, signed cookie value, customer PII.

```text
REDIS_GENERATION_CAN_ONLY_MOVE_FORWARD=YES
```

(per browser session + `ticket_issue_id`; stale generation cannot overwrite newer binding)

### Generation fingerprint v1 (unchanged)

```text
digest = SHA-256("ticket-session:v1:" <> current_delivery_token_hash)
delivery_generation_fingerprint = Base.url_encode64(digest, padding: false)
```

### Session registry TTL (frozen)

```text
ticket_browser_session_idle_ttl_seconds = 86400
```

Refresh TTL only after: successful exchange; successful authorized HTML read; successful authorized PDF read.

Do **not** refresh on: invalid cookie, invalid route id, expired/revoked ticket, malformed session, unauthorized enumeration.

Idle expiry requires fresh fragment exchange; does **not** extend `DeliveryToken` validity.

### Multi-ticket invariant (unchanged semantics)

```text
one browser cookie
one Redis session HASH
many independent ticket fields

exchange A → HSET ticket:A
exchange B → HSET ticket:B
GET /t/view/A → A only
GET /t/view/B → B only
rotation/revoke/expiry of A → compare-and-delete field A only; B remains
```

`ticket_issue_id` in URL is a **non-secret selector**. Authorization requires:

```text
valid browser session cookie
AND Redis field for that ticket
AND Redis generation == TicketIssue.delivery_token_generation
AND Redis fingerprint == fingerprint(current delivery_token_hash)
AND expiry / revocation / ArtifactResolver
```

Route id alone **never** grants access.

### Same-ticket rotation

Successful exchange for ticket A: atomic bind replaces field `ticket:A` only (see atomicity below).

### Redis session atomicity (v1.4 — frozen)

#### Generation-aware atomic session bind (exchange)

Inputs: `incoming_generation`, `incoming_fingerprint`, encoded value `v1:<G>:<F>`.

One Redis-side Lua/EVAL (or equivalent) must atomically bind **and**:

```text
EXPIRE session-key 86400   (only on successful bind outcomes below)
```

`SESSION_BINDING_WITHOUT_TTL=IMPOSSIBLE` — no unprotected client `HSET` then `EXPIRE`.

Outcomes (inspect current field atomically):

| Case | Action | Result |
|------|--------|--------|
| No current field | SET incoming | `BOUND` |
| Current `G1`, incoming `G2` where `G2 > G1` | replace; refresh TTL | `BOUND` |
| Current `G2/F2`, incoming `G2/F2` | idempotent; refresh TTL | `BOUND` |
| Current `G2`, incoming `G1` (`G1 < G2`) | **no mutation**; no TTL refresh | `STALE_GENERATION` |
| Current `G2/Fa`, incoming `G2/Fb`, `Fa != Fb` | **no mutation**; fail closed | `GENERATION_CONFLICT` |

**Lower generation bind rejected:** older exchange must never overwrite newer binding (`G2` outranks `G1`).

#### Exchange flow (frozen)

```text
1. hash/verify plaintext delivery token (DeliveryToken)
2. load TicketIssue: id, delivery_token_hash, delivery_token_expires_at, delivery_token_generation
3. derive fingerprint v1 from current hash
4. obtain/create browser_session_id (memory until success)
5. generation-aware atomic Redis bind + TTL
6. if BOUND: re-read TicketIssue generation + hash; require generation and fingerprint still match bound values and token still valid
7. only then Set-Cookie and return /t/view/:ticket_issue_id
8. else: generation-aware compare-and-delete stale binding where safe; fail exchange
```

Post-bind Postgres revalidation closes validation→bind races. Do not issue cookie after observing DB advanced past bound generation.

**Post-bind rotation semantics:** absolute lock with future rotation is impossible; freeze:

```text
NO STALE GENERATION CAN AUTHORIZE AN ARTIFACT
```

Stale Redis/browser state after rotation may require customer re-exchange via current fragment; reads always revalidate Postgres.

#### Exchange ordering (cookie)

Cookie only after successful registry bind **and** post-bind durable check. Redis bind failure → safe customer failure, no cookie.

#### Conditional terminal invalidation (compare-and-delete)

Never unconditional `HDEL` after prior observation.

Atomic `conditional_remove_ticket(session_key, ticket_field, expected_encoded_value)` where `expected_encoded_value` is full `v1:<G>:<F>` observed:

```text
if HGET == expected_encoded_value: HDEL; REMOVED
else: NOT_REMOVED (leave field, including newer G2)
```

Stale `G1/F1` invalidation must not remove concurrent `G2/F2`.

#### Empty HASH behavior

Do **not** implement unsafe client-side `HLEN` then `DEL` cleanup races. If removing the final field deletes the empty key, rely on normal Redis behavior. No full-key deletion from stale emptiness observations.

#### Successful read TTL refresh

After successful: Redis binding matches `delivery_token_generation` + fingerprint + expiry/revocation + `ArtifactResolver` — refresh TTL to `86400`.

If the key disappeared concurrently, TTL refresh **must not** recreate the HASH or fields. Complete the current request only per frozen resolution semantics; subsequent requests require re-exchange when registry is absent. Do not silently rebuild missing session authority.

### Redis failure (fail closed)

If Redis unavailable:

```text
POST /t/session → safe failure
GET /t/view/:id → safe failure
GET /t/view/:id/pdf → safe failure
```

No bearer in URL/query fallback; no authority from route id alone; generic customer-safe response; bounded ops telemetry (no secrets).

Redis is **required** for v1.3 browser ticket sessions. Redis is **not** durable ticket authority.

---

## Redis session lifecycle

| State | Trigger | Guard | Side effect | Terminal |
|-------|---------|-------|-------------|----------|
| `absent` | `GET /t` | no usable session | bootstrap | no |
| `active` | `POST /t/session` | valid bearer | atomic HSET+EXPIRE for field; then cookie | no |
| `active` | view/PDF read | session + field + durable checks | render; TTL refresh if key exists | no |
| `ticket_rotated` | read | generation/fingerprint ≠ DB | compare-and-delete exact observed binding; deny | for that ticket |
| `ticket_expired` | read | delivery expiry | compare-and-delete if match; deny | for that ticket |
| `ticket_revoked` | read | revoked | compare-and-delete if match; deny | for that ticket |
| `ticket_unavailable` | read | artifact failure | compare-and-delete if match; deny | for that ticket |
| `session_expired` | Redis key missing | — | re-exchange via fragment | yes |
| `registry_unavailable` | Redis down | — | fail closed | temporary |

Terminal invalidation for ticket A must not remove fields for B/C.

---

## HTTP route contract (frozen — v1.2 preserved)

```text
GET  /t
POST /t/session
GET  /t/view/:ticket_issue_id
GET  /t/view/:ticket_issue_id/pdf
```

No generic `/t/pdf`. `GET /t` bootstrap **only**. CSRF on exchange. Legacy cutover per v1.1 (compatibility then P1E-F).

---

## Browser bootstrap, artifact/PDF, WhatsApp

*(Same as v1.2 except authorization via Redis field + session cookie, not per-ticket cookie Path.)*

PDF/HTML: `HGET` for `ticket:<route_id>`; never resolve another ticket’s field.

WhatsApp: `FastCheckWeb.Endpoint.url() <> "/t#" <> token`.

---

## Legacy-link cutover (v1.1 — unchanged)

```text
P1E_LEGACY_INVENTORY_GATE → NONE | REQUIRES_CUTOVER
Stage 1: P1E-B–E compatibility (legacy /t/:token may still resolve)
P1E-E2: cohort rotate/resend with fragment worker
LEGACY_CURRENT_GENERATIONS_REPLACED=PASS
Stage 2: P1E-F hard cutover (conditional)
```

```text
Do NOT issue P1E-F until gate authorizes.
```

Rotation invalidates old path bearer and **that ticket’s** Redis registry field.

---

## App-log regression provenance

| Field | Value |
|-------|-------|
| `ACTIVE_RAILWAY_GIT_SHA` | `a8a3d830629f8e2fa915fed85cbcf94268cebc60` |
| PR #494 | `368b6d73f56dc2bae88aad5b634b36b2688a6c5c` |
| Distance | **40 commits** |

`PR494_LOG_HARDENING_PRESENT_IN_DEPLOYMENT=NO` — `STALE_DEPLOYMENT`

---

## Observability / redaction

- v1.1 `/t/...` path redaction; `delivery_token` on exchange body.
- Safe: numeric `ticket_issue_id` where policy allows.
- **Never log:** cookie value, browser session id, Redis session secrets, fingerprint, delivery token, raw hash, rate-limit credential fingerprint, Set-Cookie values in Sentry.
- `POST /t/session` must not set `conn.private[:raw_body]` (webhook-only `RawBodyReader`).

---

## Rate limiting (v1.3 — frozen)

### Reject node-local security counters for new limits

v1.2’s **PlugAttack/Ets-only** model for new secure-ticket limits is **rejected**: effective ceiling multiplies by replica count (`N × limit`). Legacy `/t/:token` policy during compatibility remains **unchanged** (existing local/legacy behavior — do not route legacy through new fragment limits unless P1E-F explicitly changes).

New P1-E limits use **shared Redis ZSET** sliding windows via existing `Redix` + `FastCheck.Redis.Namespace`. **Do not** use `PlugAttack.Storage.Redis` (not in plug_attack 0.4.3). **Do not** add a new dependency. Implement a small FastCheck-owned **atomic** boundary (Lua/EVAL).

**Frozen clock (v1.4):**

```text
CLOCK_SOURCE=Redis TIME
```

Sliding-window timestamps must come from Redis, not independent app-node clocks.

**Frozen ZSET member (v1.4):**

```text
member = <redis-time-microseconds>:<cryptographically-random-nonce>
score  = Redis-derived timestamp
```

ZSET members are unique; **timestamp-only members are forbidden** (concurrent requests would undercount).

**Atomic algorithm (one Redis-side operation):**

```text
1. Redis TIME
2. prune scores older than window
3. ZCARD
4. if below limit: ZADD unique member
5. set/refresh bounded key expiry
6. return allow/block + reset/retry metadata
```

No read-decide-write split across client commands.

Do not fix unrelated mobile rate-limit backend debt in P1E unless separately authorized.

### Namespace (conceptual)

```text
rate-limit:secure-ticket:exchange-token:<credential-fingerprint>
rate-limit:secure-ticket:exchange-ip:<client-identity>
rate-limit:secure-ticket:session:<browser-session-hash>
rate-limit:secure-ticket:read-ip:<client-identity>
```

Exchange credential fingerprint (rate limit only, in-memory):

```text
SHA-256("secure-ticket-rate-limit:v1:" <> delivery_token)
```

(encoded deterministically; never logged; not ticket authority)

### Layers (frozen)

Exchange:

```text
A. per-credential: secure_ticket_exchange_token_limit = 5/min
B. per-client-IP:   secure_ticket_exchange_ip_limit   = 600/min
```

Session reads (`/t/view/...`):

```text
A. per-browser-session: secure_ticket_session_read_limit    = 120/min
B. per-client-IP:       secure_ticket_session_read_ip_limit = 1200/min
```

Rationale: 50 tickets/order; ~10 max-size customers behind one NAT on exchange IP; session bucket avoids cross-ticket collision; broad IP guards are defense-in-depth.

`GET /t` bootstrap: no ticket lookup; not charged to exchange bucket.

### Trusted client IP (v1.4 — frozen)

```text
TRUST_ARBITRARY_X_FORWARDED_FOR=NO
```

For broad IP guards, derive identity deterministically:

```text
outer_peer = Railway-provided X-Real-IP (remote IP presented to Railway edge)
```

Trust **`CF-Connecting-IP`** as visitor IP **only when**:

```text
outer_peer parses as a valid IP
AND outer_peer belongs to configured trusted Cloudflare proxy CIDRs (IPv4 + IPv6)
AND CF-Connecting-IP parses as a valid IPv4 or IPv6 address
```

Then:

```text
client_ip = CF-Connecting-IP
```

Otherwise (including direct Railway public origin without Cloudflare hop):

```text
client_ip = outer_peer (X-Real-IP) when valid
```

Never use arbitrary first `X-Forwarded-For` as P1-E security identity.

**Trusted Cloudflare CIDR configuration:** explicit deploy-time CIDR authority; IPv4+IPv6; documented maintenance; invalid CIDRs fail closed or reject config; **no** dynamic web lookup on request path. Direct-origin traffic must not spoof broad-IP identity by supplying `CF-Connecting-IP` without a trusted Cloudflare outer peer.

**Identity degradation:** per-credential and per-browser-session Redis limits remain primary. If trustworthy client IP cannot be derived, do not fall back to attacker-controlled `X-Forwarded-For`; use safely available outer-peer identity or a conservative documented fallback. Do not silently disable broad guards.

### Rate-limit failure

Never silently disable. Redis rate-limit failure → same safe fail-closed posture as registry unavailability for protected routes. Log/metric without secrets.

### Capacity test (P1E-G)

Before P1E-G passes:

```text
10 concurrent customers, same apparent client IP, 50 exchanges each → must not trip broad exchange ceiling
per-token >5/min blocks
per-session >120/min blocks
broad IP overflow blocks
limits do not multiply across simulated nodes/backends
```

---

## Performance / scaling review

| Item | Value |
|------|-------|
| HOT | one opaque browser cookie (`_fastcheck_ticket_session`) |
| WARM | Redis HASH browser ticket-session; idle TTL 86400s |
| WARM | Redis ZSET rate limits; 60s windows; bounded TTL |
| COLD | Postgres `TicketIssue` + `ArtifactResolver` |
| NEW_DB_TABLE | NO |
| MIGRATION_REQUIRED | YES (`delivery_token_generation` column) |
| NEW_INDEX_REQUIRED | NO |
| NEW_DB_WRITES_PER_VIEW | 0 |
| ROTATION_DB_WRITE | +1 integer increment (atomic with hash/expiry) |
| REDIS_HASH_WRITES | atomic bind, compare-and-delete on terminal, conditional TTL refresh |
| REDIS_HASH_READS | HGET per view/PDF (single-field; no full HASH load for one ticket) |
| PUBSUB | none required |
| OBAN | unchanged |
| MULTI_TICKET_50_COUNT_SAFE | YES (one cookie + up to 50 HASH fields) |

**Session registry:**

```text
DATA_LAYER=WARM_REDIS
STRUCTURE=HASH
TTL=86400s idle
ATOMIC_BIND=YES
ATOMIC_COMPARE_DELETE=YES
INVALIDATION=compare-and-delete on generation mismatch, expiry, revocation, artifact unavailable; idle expiry
```

**Rate limiting:**

```text
DATA_LAYER=WARM_REDIS
STRUCTURE=ZSET
WINDOW=60s
CLOCK=Redis TIME
MEMBER=unique per request (<redis-time>:<nonce>)
ATOMICITY=Redis-side
```

**Review status:** PASS

---

## Security threat review

| Topic | Mitigation |
|-------|------------|
| 50-ticket cookie eviction | One cookie + Redis HASH |
| Multi-ticket collision | Per-field registry + route id |
| Redis not durable authority | Always revalidate Postgres |
| Plaintext not in Redis | Fingerprints only |
| HttpOnly / Secure / SameSite / Path=/t | Cookie hardening |
| CSRF on exchange | `protect_from_forgery` |
| Distributed rate limits | Redis ZSET, not per-node ETS |
| IP spoofing | CIDR-gated CF-Connecting-IP; never trust X-Forwarded-For |
| Stale invalidation race | Compare-and-delete; G1 cannot remove G2 |
| Stale exchange overwrite | Generation-aware bind; G1 cannot replace G2 |
| Session bind without TTL | Atomic bind+EXPIRE |
| Legacy cutover | v1.1 two-stage preserved |
| Ingress / fragment | v1.1/v1.2 preserved |

**Review status:** PASS

---

## Implementation phases (frozen)

| Phase | Deliverable |
|-------|-------------|
| **P1E-A** | Provenance + plan + legacy inventory gate |
| **P1E-B** | `delivery_token_generation` migration + atomic rotation; browser session; generation-aware Redis bind/compare-delete; fingerprint |
| **P1E-C** | Exchange; generation-aware bind; post-bind Postgres revalidation; cookie |
| **P1E-D** | View/PDF; generation + fingerprint + durable checks; multi-ticket isolation |
| **P1E-E** | WhatsApp `/t#` |
| **P1E-E2** | Legacy cohort (operational) |
| **P1E-F** | Legacy rejection — **conditional** |
| **P1E-G** | 50-ticket cookie test; Redis concurrency; rate-limit clock/member tests; client-IP tests |
| **P1E-H** | Production ingress canary |
| **P1E-I** | Gate closure |

---

## Test / evidence strategy

Retain v1.1/v1.2 tests (routes, fragment, legacy stages, redaction, raw body).

**Mandatory v1.3** (retained):

```text
1 ticket → 1 browser session cookie
50 tickets → still 1 browser session cookie
Redis HASH fields A/B independent
Redis session expiry → require fragment re-exchange
Redis unavailable → no artifact
cookie: no token/hash/fingerprint list
Redis key: no raw browser_session_id
rate-limit keys: no raw delivery token
shared Redis limits: no per-node multiplication
```

**Mandatory v1.4 (concurrency + IP):**

```text
stale F1 invalidation racing fresh F2 exchange preserves F2
atomic bind never creates session HASH without TTL
terminal invalidation removes exactly the observed generation (compare-and-delete)
terminal invalidation of A never removes B
rate limiter counts concurrent same-microsecond requests independently (unique ZSET members)
rate limiter uses one Redis clock across simulated app nodes

trusted Cloudflare outer IP + valid CF-Connecting-IP → use CF visitor IP
untrusted outer IP + spoofed CF-Connecting-IP → ignore CF header
arbitrary X-Forwarded-For → not trusted
IPv4 and IPv6 trusted proxy CIDRs supported
```

**Mandatory v1.5 (generation ordering):**

```text
DB: migrated rows default generation 0; initial token G0; rotation G0→G1→G2; concurrent rotations no duplicate G
DB: hash + expiry + generation one atomic transition

Redis bind: empty+G1→G1; G1+incoming G2→G2; G2+incoming G1→stays G2 (STALE_GENERATION)
G2/F2 + G2/F2 idempotent; G2/Fa + G2/Fb → GENERATION_CONFLICT
stale G1 exchange racing fresh G2 → final registry G2 (both orderings)
bind + TTL atomic

Auth: Redis G1 while DB G2 → no HTML/PDF; mismatch cleanup cannot remove G2
fresh G2 authorizes after stale G1 activity
```

Plus v1.2 cross-ticket HTML/PDF isolation cases (via registry fields).

**P1E-H** paths unchanged (`/t`, `/t/session`, `/t/view/<id>`, optional pdf).

**Migration safety:** bounded column add; existing rows `generation=0`; reversible per repo conventions; no destructive token rotation in migration.

---

## Production cutover / rollback / STOP conditions

Production sequencing and rollback: **v1.1 unchanged** (compatibility → E2 → F; no path-token generation rollback).

**Additional STOP conditions:**

- Per-ticket cookie fan-out remains required for 50-ticket flow.
- Redis becomes durable ticket authority or bypasses Postgres checks.
- Plaintext bearer in Redis.
- Node-local ETS as production authority for **new** P1-E limits.
- Dependence on `PlugAttack.Storage.Redis`.
- Non-atomic Redis rate-limit updates.
- Application-node clocks define distributed sliding windows.
- ZSET timestamp-only members (collision under concurrency).
- Redis session binding without TTL (`SESSION_BINDING_WITHOUT_TTL` possible).
- Terminal invalidation uses unconditional HDEL after prior HGET.
- Stale F1 can delete concurrently written F2.
- `CF-Connecting-IP` trusted without trusted Cloudflare outer peer (CIDR).
- Arbitrary `X-Forwarded-For` as authoritative P1-E identity.
- Weakened legacy cutover.
- Timestamps used as generation ordering.
- Concurrent rotations persist same generation.
- Lower Redis generation overwrites higher generation.
- Same generation + different fingerprint silently accepted.
- Stale Redis binding authorizes artifact after DB generation advances.
- Rotation requires synchronous Redis mutation in DB transaction.
- Unnecessary index on `delivery_token_generation`.
- Claim `MIGRATION_REQUIRED=NO` for P1-E session ordering.

---

## Confirmed P1-E defect

```text
RAILWAY_RAW_PATH_LOGGING=CONFIRMED
INGRESS_REQUEST_LOGGING_SAFE=FAIL until P1E-H after hard cutover
```

---

## Success criteria

```text
delivery bearer not in HTTP request target (steady state new flow)
MAX_TICKET_SESSION_COOKIES=1
multi-ticket support = YES (50/order)
multi-tab collision = NO
WARM Redis session registry = YES (ephemeral bindings only)
NEW_DB_TABLE = NO
MIGRATION_REQUIRED = YES (delivery_token_generation)
NEW_INDEX_REQUIRED = NO
REDIS_GENERATION_FORWARD_ONLY = YES
NO STALE GENERATION ARTIFACT AUTHORIZATION = YES
distributed rate limits = YES
legacy two-stage cutover = preserved
P1-E gate = PASS only after P1E-H
```
