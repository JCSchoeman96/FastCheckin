# WhatsApp Customer Service, Navigation, Resend Identity, and E2E Test Design

**Status:** DRAFT FOR WRITTEN REVIEW  
**Date:** 2026-10-15  
**Repository:** `JCSchoeman96/FastCheckin`  
**Authority base:** `d8e885a08d91f9290e1ff2519003fbdfc014831d`  
**Scope:** WhatsApp customer navigation, direct human support handoff, ticket resend identity flow, and controlled end-to-end test event.

## 1. Ultimate Goal and Backward Planning

### 1.1 Ultimate long-term goal

FastCheck WhatsApp must become a trustworthy customer channel where a person can:

1. buy tickets;
2. recover or resend an issued ticket;
3. obtain human help in the same WhatsApp conversation;
4. always understand what they can do next;
5. recover safely from bad input, unavailable inventory, payment uncertainty, stale conversation state, or support escalation;
6. complete these flows without unnecessary identity questions;
7. receive no duplicate orders, duplicate tickets, or another customer's ticket; and
8. be supported at production scale without making Postgres the immediate read source for every hot-path operation.

The WhatsApp experience must never intentionally present a non-terminal customer-facing response with no next action.

### 1.2 Systems required to reach that outcome

Working backwards from the goal requires these systems in dependency order:

1. **Deterministic navigation contract** — one main menu, one universal escape convention, no meaningless Back action, and no customer dead ends.
2. **Safe resend identity contract** — email first, email OTP as proof, WhatsApp phone as a ranking/correlation signal only, and one-ticket-at-a-time selection after verification.
3. **Human support lifecycle** — customer can request help, describe the problem, enter a waiting state, remain in the same WhatsApp thread, and be claimed/replied to/resolved by an authorized operator.
4. **Bot/human routing boundary** — while a support case is waiting or claimed, customer text must not accidentally execute sales state transitions.
5. **Operator support inbox** — realtime waiting/claimed queues, explicit claim ownership, reply delivery, delivery status, and resolution.
6. **Reusable E2E certification event** — controlled event/offer/inventory/payment/ticket/resend/support test data with an explicit enable/disable runbook.
7. **Observability, rate limits, privacy, and performance architecture** — bounded queries, hashed identifiers in Redis/rate-limit keys, encrypted support message bodies, PubSub instead of polling, Oban for delivery, and indexes for every critical query path.

### 1.3 MVP

The smallest viable slice of the long-term system is:

- main menu contains only Buy tickets, Help, and Re-send my ticket;
- `0` means **Main menu** in subflows and is not shown on the main menu;
- `#` remains accepted only as a hidden backward-compatibility alias for Main menu and is no longer advertised;
- every non-terminal response contains either an explicit input request or at least one explicit action;
- Help asks for one short free-text problem description and immediately creates a human support case;
- support operators can see, claim, reply to, and resolve cases in the same WhatsApp conversation;
- resend asks for email first, verifies ownership by email OTP, and then selects one ticket if multiple eligible tickets exist;
- name is not required for normal resend identity;
- current WhatsApp phone/WA ID is used only to rank or correlate candidates, never as authentication;
- a controlled WhatsApp E2E test event is created through supported application paths, uses Paystack test mode, and is disabled again after certification.

Self-service FAQ automation, AI support, category routing, resend-all, and fuzzy name matching are explicitly deferred.

---

## 2. Non-negotiable UX and Safety Invariants

1. **No dead ends.** Every non-terminal customer-visible response has an obvious next action or explicitly asks for the next input.
2. **No meaningless navigation.** The main menu never shows `0. Back` because there is nowhere to go back to.
3. **One escape concept.** In subflows, `0. Main menu` is the only advertised global escape.
4. **No advertised `#`.** `#` remains a hidden compatibility alias so old instructions/messages do not strand customers.
5. **Explicit correction beats generic Back.** When a correction is valuable, show a concrete action such as `1. Change email` instead of relying on ambiguous Back semantics.
6. **Phone is not identity proof.** `phone_e164` / `wa_id` may narrow/rank lookup candidates but may never authorize resend.
7. **Email OTP is identity proof for resend.** No ticket candidate may be delivered before the email challenge is verified.
8. **One ticket at a time.** If multiple eligible tickets exist, the customer selects exactly one ticket for resend.
9. **No fuzzy identity matching.** Do not make resend authorization depend on typo-tolerant/fuzzy name matching.
10. **Support suppresses bot execution.** While a support case is `waiting` or `claimed`, ordinary customer text is support text, not sales/menu input; only global control commands may escape.
11. **One active support case per conversation.** Concurrent waiting/claimed cases for the same WhatsApp conversation are forbidden.
12. **Operator replies cannot choose recipients.** Recipient identity comes only from the bound Conversation; staff cannot type or override a destination phone number.
13. **No raw PII in logs, Oban arguments, Redis keys, PubSub topics, or metrics.** Use internal IDs or keyed hashes.
14. **Postgres remains durable authority.** Redis/ETS/GenServer state is a hot/warm mirror and cannot become the sole durable record.
15. **Optimistic concurrency is mandatory** on operator claim/resolve and any one-time resend candidate binding.
16. **Every critical query path has an index.** No production table scan is acceptable for support queues or resend discovery.

---

## 3. Current-State Findings that Drive This Design

The current system already provides useful foundations:

- `Conversation` stores `phone_e164`, `wa_id`, durable state, `needs_human`, and `handoff_reason`.
- `Conversation` already exposes `list_needing_human` and has a `handoff_conversation` transition to `manual_review`.
- the WhatsApp inbound pipeline already carries `phone_e164` and `wa_id` into resend request source metadata.
- resend normalization already lowercases/trims email and lowercases/normalizes names.
- `sales_orders` already has an index on `buyer_phone`.
- `TicketResendChallenge` already permits nullable `sales_order_id`, `ticket_issue_id`, `request_name_hash`, and `candidate_hash`, which makes identity-level OTP verification possible without binding a ticket before verification.
- the current resend query requires normalized email + normalized name and returns ambiguity when two or more ticket candidates match.
- the current renderer advertises both `0. Back` and `#. Back to main menu`, and the main menu itself incorrectly includes `0. Back`.
- several customer responses such as no-events/payment-status responses can contain explanatory text without a next action.
- the repository has no complete operator support inbox / same-thread human-reply lifecycle.

This design therefore evolves existing capabilities rather than introducing a second conversation system.

---

## 4. Domain and Resource Map

### 4.1 Existing domains retained

#### `FastCheck.Messaging.WhatsApp`
Responsibilities:
- inbound normalization;
- customer menu rendering;
- bot conversation orchestration;
- outbound Meta client;
- resend orchestration adapter;
- routing customer messages between bot mode and human-support mode.

It must not become the durable owner of support cases or ticket identity.

#### `FastCheck.Sales`
Responsibilities retained:
- `Conversation` durable WhatsApp checkpoint;
- Order/commercial lifecycle;
- `TicketResendChallenge` durable OTP lifecycle;
- payment/order identity and active commercial-order guards.

#### `FastCheck.Tickets.Resend`
Responsibilities:
- normalize resend identity input;
- discover eligible tickets;
- create/verify resend challenges;
- enforce rate limits;
- bind exactly one selected ticket after verification;
- enqueue verified resend delivery.

### 4.2 New domain: `FastCheck.Support`

Human support is cross-cutting and should not be hidden inside `Sales.Conversation.state_data`.

#### `SupportCase`
Durable lifecycle record for one human-support engagement.

Recommended fields:

- `id`
- `public_id`
- `conversation_id` (required)
- `state` (`waiting`, `claimed`, `resolved`, `cancelled`)
- `reason_code` (`customer_requested_support` initially; bounded enum)
- `assigned_operator_id` / existing authenticated-user identity reference
- `requested_at`
- `claimed_at`
- `resolved_at`
- `cancelled_at`
- `last_customer_message_at`
- `last_operator_message_at`
- `lock_version`
- timestamps

Optional contextual references that may be attached by the system, never trusted from customer text:

- `sales_order_id`
- `event_id`

#### `SupportMessage`
Durable, encrypted message record for the support portion of a conversation.

Recommended fields:

- `id`
- `support_case_id`
- `direction` (`customer`, `operator`, `system`)
- `sender_operator_id` nullable
- `provider_message_id` nullable but unique where present
- `body_ciphertext`
- `delivery_state` (`received`, `pending`, `sent`, `failed`)
- `provider_reference_hash` nullable
- `failure_class` nullable, bounded and non-sensitive
- timestamps

Plaintext message bodies must not be persisted outside the approved encryption boundary.

#### `SupportQueue.Server`
Hot-state coordinator/aggregator only.

Responsibilities:
- maintain hot waiting/claimed queue summaries in ETS;
- coordinate local transition intent before durable write;
- publish queue counters and case updates;
- never act as exclusive cross-node lock or durable authority.

DB optimistic locking is still the final concurrency authority.

#### `SupportOutboundWorker`
Oban worker for operator-originated WhatsApp replies.

Responsibilities:
- load the case/message by internal ID;
- decrypt only inside the delivery boundary;
- enforce WhatsApp freeform/template window policy;
- call the existing Meta WhatsApp client;
- persist delivery outcome;
- broadcast PubSub update.

Oban args contain IDs only, never plaintext or phone numbers.

### 4.3 Relationships

```text
Conversation 1 ─── 0..* SupportCase
SupportCase   1 ─── 1..* SupportMessage
Conversation 1 ─── 0..* TicketResendChallenge
Conversation 1 ─── 0..* SalesOrder
SalesOrder    1 ─── 0..* TicketIssue
TicketIssue   1 ─── 1 Attendee
```

Invariant: at most one SupportCase for a Conversation may be in `waiting` or `claimed`.

---

## 5. State Machines

## 5.1 Customer navigation state contract

### Main menu

```text
MAIN_MENU
  1 → BUY_TICKETS
  2 → SUPPORT_DESCRIPTION
  3 → RESEND_EMAIL
```

No `0` and no `#` are displayed on the main menu.

### Universal subflow escape

For all bot subflows where escape is safe:

```text
ANY_SUBFLOW --0--> SAFE_MAIN_MENU_RECOVERY
```

`SAFE_MAIN_MENU_RECOVERY` must use the existing active-commercial-order guard. It must not discard or duplicate an active Order.

Hidden compatibility:

```text
ANY_SUPPORTED_STATE --#--> SAFE_MAIN_MENU_RECOVERY
```

`#` remains recognized but is no longer rendered.

### Guard

If an active Order exists, “Main menu” resolves to the context-aware active-order menu, not a blank fresh checkout menu.

### Side effects

- transient pre-order selection state may be cleared when safely returning to the main menu;
- existing durable active Order identity is preserved;
- active payment/fulfillment state is never cancelled merely because `0` was entered.

---

## 5.2 Resend lifecycle

### Conversation states

Preferred new active path:

```text
main_menu
  └─ choose_resend_ticket → collecting_resend_email

collecting_resend_email
  ├─ valid email → collecting_resend_otp
  └─ 0 → main_menu

collecting_resend_otp
  ├─ verified + one eligible ticket → awaiting_verified_resend_delivery
  ├─ verified + multiple eligible tickets → selecting_resend_ticket
  ├─ invalid/expired OTP → remain collecting_resend_otp
  ├─ locked → support-capable response
  └─ 0 → invalidate challenge + main_menu

selecting_resend_ticket
  ├─ valid selection → awaiting_verified_resend_delivery
  ├─ too many candidates / unsafe ambiguity → human support
  └─ 0 → invalidate challenge + main_menu

awaiting_verified_resend_delivery
  └─ queue delivery → verified_resend_delivery_queued

verified_resend_delivery_queued
  └─ delivery completes asynchronously
```

The old `collecting_resend_name` state is removed from the normal customer path but must remain migration/backward-compatible until existing durable conversations are safely transitioned.

### Challenge states

Existing challenge lifecycle remains authoritative:

```text
pending
  ├─ correct OTP → verified
  ├─ too many failures → blocked [terminal for that challenge]
  ├─ timeout / customer exits → expired [terminal]
  └─ exceptional safety condition → manual_review [terminal]

verified
  ├─ bind exactly one eligible candidate
  ├─ successful queue → consumed [terminal]
  └─ timeout / customer exits before use → expired [terminal]
```

Candidate binding must be one-time and optimistic-lock protected. A verified challenge may never be rebound to a different ticket after one candidate is bound.

### Candidate discovery

1. normalize email using existing lower/trim behavior;
2. obtain current Conversation `phone_e164` / `wa_id` as a system-owned correlation signal;
3. query eligible issued/valid ticket candidates by normalized email using a bounded indexed query;
4. annotate/rank exact buyer-phone matches first but do **not** exclude nonmatching-phone candidates;
5. issue email OTP without requiring typed name;
6. after OTP verification, recompute/bound the eligible candidate set before exposing choices;
7. one eligible candidate → bind automatically;
8. 2–9 eligible candidates → show numbered ticket choices;
9. >9 candidates or an invariant failure → direct human-support path rather than an unbounded WhatsApp list.

### Customer-visible ticket labels

Only after OTP verification, show the minimum necessary disambiguation fields, for example:

```text
1. Voelgoed Live — Jan Schoeman
2. Voelgoed Live — Marie Schoeman
```

Never expose internal order IDs, ticket issue IDs, email addresses, hashes, or payment references.

### Why name is removed

Name normalization remains useful for legacy tooling and display, but normal resend authorization no longer depends on exact/fuzzy name input. This avoids spelling failures without introducing insecure fuzzy matching.

---

## 5.3 Human support lifecycle

### Entry

Main menu:

```text
2. Hulp
```

Bot response:

```text
Waarmee kan ons jou help?
Tik asseblief kortliks waarmee jy hulp nodig het.

0. Hoofkieslys
```

At this stage no support case exists yet.

### Customer submits description

Transition:

```text
support_description
  --nonblank text-->
create SupportCase(state=waiting)
+ create encrypted SupportMessage(direction=customer)
+ set Conversation.needs_human=true
+ set support-specific handoff reason
+ broadcast PubSub
```

Customer response:

```text
Dankie. Ons het jou boodskap ontvang.
Iemand van ondersteuning sal hier op WhatsApp antwoord.

0. Verlaat ondersteuning en gaan na hoofkieslys
```

### SupportCase states

```text
waiting
  ├─ operator claim → claimed
  ├─ customer 0 → cancelled [terminal]
  └─ administrative close → cancelled [terminal]

claimed
  ├─ operator reply → claimed
  ├─ customer message → claimed
  ├─ operator resolve → resolved [terminal]
  └─ customer 0 → cancelled [terminal]
```

No automatic `waiting -> resolved` timeout is allowed without an explicit product rule. A stale-case maintenance job may flag or alert, but must not silently discard a customer's support request.

### Bot suppression rule

When an active support case exists:

- arbitrary text, numbers, and attachments belong to the support case;
- they must not execute buy/resend/payment menu transitions;
- `0` is reserved to cancel/leave support and recover safely to the main menu;
- existing global STOP/privacy behavior remains authoritative and must not be repurposed;
- `#` may remain a hidden backward-compatible main-menu escape if existing global semantics require it.

### Claim concurrency

Two operators may attempt to claim the same case.

Guard:

```text
waiting + expected lock_version
  → exactly one claim succeeds
  → loser receives already_claimed/stale_version
```

Redis/GenServer may provide hot queue hints but may not replace the DB guard.

### Resolve side effects

When a support case resolves/cancels:

- active-case Redis/ETS mirrors are invalidated;
- queue PubSub update is broadcast;
- `Conversation.needs_human` is cleared only if no other active support/safety reason remains;
- support-specific `handoff_reason` is cleared only if it is the reason currently present;
- underlying Sales Order remains untouched;
- next bot interaction routes through safe main-menu recovery.

---

## 5.4 Support outbound delivery lifecycle

```text
pending
  ├─ Meta accepts → sent [terminal]
  ├─ retryable transport/rate error → pending/retry scheduled
  └─ permanent auth/validation failure → failed [terminal + operator-visible]
```

Guards:

- sender is an authorized support operator;
- case is `claimed` by that operator, unless an explicit supervisor override policy is later added;
- destination derives from Conversation only;
- freeform text may be sent only inside Meta's customer-service window;
- outside that window, only an approved template path may be used.

Heavy or retryable delivery work must run in Oban, never block LiveView.

---

## 6. Navigation and Copy Contract

## 6.1 Main menu

Afrikaans:

```text
Kies 'n opsie:

1. Koop kaartjies
2. Hulp
3. Stuur my kaartjie weer
```

English:

```text
Choose an option:

1. Buy tickets
2. Help
3. Re-send my ticket
```

No Back action is rendered.

## 6.2 Subflow footer

Default advertised footer:

```text
0. Hoofkieslys
```

English:

```text
0. Main menu
```

`#. Back to main menu` is removed from rendered copy.

## 6.3 Invalid input

Invalid input must repeat the current actionable prompt rather than only say “invalid”.

Example:

```text
Antwoord asseblief met een van die opsies hier onder.

Kies 'n opsie:
1. Koop kaartjies
2. Hulp
3. Stuur my kaartjie weer
```

## 6.4 No tickets available

Not allowed:

```text
Daar is nie nou kaartjies beskikbaar nie. Probeer asseblief later weer.
```

Required shape:

```text
Daar is nie nou kaartjies beskikbaar nie.

1. Hulp
0. Hoofkieslys
```

## 6.5 Payment/status/unavailable responses

Any response that leaves the customer waiting or blocked must include at least one useful next action, normally Help plus Main menu. The exact active-order menu remains context-aware and must not create a second Order.

## 6.6 Explicit correction

Do not revive generic Back as a universal navigation feature. If a screen needs correction, use explicit customer language, e.g.:

```text
1. Verander e-posadres
0. Hoofkieslys
```

---

## 7. Operator Support Inbox

### 7.1 MVP surfaces

Recommended routes:

```text
/dashboard/support
/dashboard/support/:support_case_id
```

Recommended modules:

```text
lib/fastcheck/support/support_case.ex
lib/fastcheck/support/support_message.ex
lib/fastcheck/support/support_queue.ex
lib/fastcheck/support/support_queue/server.ex
lib/fastcheck/support/policy_checks.ex
lib/fastcheck/workers/support_outbound_worker.ex

lib/fastcheck_web/live/support/inbox_live.ex
lib/fastcheck_web/live/support/case_live.ex
```

Tests mirror these paths.

### 7.2 Inbox behavior

Inbox lists:

- Waiting cases, oldest first;
- My claimed cases;
- optionally recently resolved cases for audit/reference.

Realtime changes use Phoenix PubSub / LiveView push. No polling.

List rows expose only the minimum operational context: wait time, preferred language, masked customer identifier, and safe event/order context when system-bound.

### 7.3 Case screen

Authorized operator can:

1. claim a waiting case;
2. read decrypted support-case messages;
3. send a reply;
4. see pending/sent/failed delivery state;
5. resolve the case.

No operator may edit customer message history or change the recipient.

### 7.4 Permissions

Reuse existing dashboard authentication; do not create a second authentication system.

Add a support-specific authorization capability/policy.

Rules:

- system actor may create/update support records from trusted webhook/worker boundaries;
- support operator may list/read/claim/reply/resolve according to support permission;
- event-only permissions do not automatically grant global access to unrelated support cases;
- if a case is event-bound, event context may further restrict access, but general help still requires an explicitly authorized global support role;
- all operator actions are audited with actor ID and timestamp.

---

## 8. Resend Query and Data Integrity Design

### 8.1 Query strategy

The current query uses `lower(buyer_email)` plus exact normalized name. The new query removes name as an authorization filter.

Required candidate predicates remain strict:

- Order status indicates issued ticket;
- TicketIssue is issued, scanner-valid, not revoked;
- Event is not archived;
- attendee is not revoked and is scan-eligible;
- payment state is completed according to the existing canonical normalization.

Then:

- filter by normalized buyer email;
- rank exact `buyer_phone == Conversation.phone_e164` first;
- order deterministically by recent Order then TicketIssue ID;
- use a bounded limit sufficient to detect `>9` without loading an unbounded customer history.

### 8.2 Required indexes

At minimum:

1. retain `sales_orders(buyer_phone)`;
2. add an indexed normalized-email query path, preferably a partial functional index such as normalized/lower buyer email for issued Orders;
3. ensure existing joins use indexed PK/FK paths on `sales_ticket_issues.sales_order_id`, attendee/event IDs, and status paths;
4. SupportCase: partial unique index on `conversation_id` for states `waiting`/`claimed`;
5. SupportCase queue index on `(state, requested_at)`;
6. SupportCase operator index on `(assigned_operator_id, state, updated_at)`;
7. SupportMessage index on `(support_case_id, inserted_at)`;
8. unique provider-message identity where available for support-message dedupe.

No query design is accepted if `EXPLAIN` shows large sequential scans on normal production cardinalities.

---

## 9. Performance and Scaling Review

### 9.1 Data layer placement

#### Hot: ETS / GenServer

- active support queue counters;
- per-node queue snapshots;
- operator presence/claimed-case hints;
- short-lived support activity aggregates.

TTL/refresh target: seconds to a few minutes. Hot state is disposable and rebuilt from Redis/Postgres.

#### Warm: Redis

Use only hashed/internal identifiers.

Recommended structures:

- resend source/email/candidate rate limits: **ZSET**, 15-minute-class TTL aligned to existing resend rate-limit design;
- active support queue mirror: **ZSET** scored by requested time;
- claimed support cases by operator: **SET** or **ZSET**;
- support activity feed for realtime operational dashboards: **LIST** with bounded length and short TTL;
- queue/case summary cache: **HASH** with 30s–5m TTL depending on field;
- unique support/inbound operational counters where useful: HyperLogLog only for aggregate metrics, never authorization.

Redis is never the ownership lock for a support case and never the source of truth for OTP verification.

#### Cold/durable: Postgres

- Conversation;
- SupportCase;
- SupportMessage ciphertext;
- TicketResendChallenge;
- Orders/TicketIssues/Attendees/Events;
- audit history.

Use PgBouncer in transaction mode for high-concurrency production paths.

#### Browser

- localStorage may hold non-sensitive support-dashboard UI preferences only;
- do **not** persist decrypted support messages, emails, phone numbers, OTPs, or ticket data in localStorage/IndexedDB;
- decrypted case content stays in LiveView/session memory only as needed.

#### CDN

Static dashboard assets remain CDN-cacheable. No support/customer PII response is CDN-cacheable.

### 9.2 Realtime

- Phoenix PubSub broadcasts support queue/case changes;
- LiveView consumes push updates; no polling;
- GenServer/ETS aggregates hot queue state;
- outbound delivery/retries use Oban;
- analytics use cached aggregates/materialized views/read replicas, never peak-time scans of support messages.

### 9.3 Concurrency

- SupportCase claim and resolve: optimistic lock/version guard;
- resend candidate bind: one-time optimistic guard;
- DB unique index prevents two active support cases for one Conversation;
- duplicate inbound provider messages remain protected by existing webhook dedupe;
- duplicate support outbound job execution must be idempotent by SupportMessage ID/provider state.

### 9.4 100k-user safety questions

- **Excess DB calls?** Hot queue views read Redis/ETS and receive PubSub deltas; durable case/message fetch occurs only when needed.
- **Redis representation?** Yes: rate limits ZSET, queue ZSET, summaries HASH, activity LIST.
- **Streaming?** Support history loads/page-streams in bounded pages; never load an unbounded conversation transcript into memory.
- **Stampede risk?** Queue-cache misses use short lock/single-flight behavior or GenServer aggregation; no mass dashboard refresh polling.
- **Analytics?** Derived from cached/materialized aggregates/read replica, never full message scans during peak.

Targets remain sub-100ms ordinary API/read latency, horizontally scalable nodes, and no new path capable of overselling or bypassing existing commercial-order guards.

---

## 10. Security, Privacy, and Abuse Controls

### 10.1 Resend

- OTP secret is stored hashed only;
- raw email is never placed in logs/metrics/Redis keys/Oban args;
- Redis keys use HMAC/hash material;
- phone match improves ranking only;
- invalid/no-match/ambiguous pre-verification responses remain enumeration-safe;
- ticket metadata is exposed only after successful OTP verification;
- candidate selection is bounded;
- OTP/challenge has TTL and failure lockout;
- leaving resend invalidates the active challenge so an abandoned verified challenge cannot later be reused.

### 10.2 Support

- support message body stored encrypted;
- message decryption only for authorized operator display or outbound delivery;
- no plaintext in logs, Oban args, PubSub payloads, Redis, or analytics;
- operator cannot change the destination identity;
- support outbound obeys Meta's 24-hour customer-service-window policy and template requirement outside it;
- one active support case prevents duplicate operators/case races;
- claim/resolve audit includes operator actor identity;
- support-case retention must be explicitly configured and must not be indefinite by accident.

### 10.3 Multi-tenant/event isolation

- event-scoped operators may not read cases unrelated to authorized event context;
- general/unbound cases require global support permission;
- customer email/phone lookups never cross tenant/event boundaries in a way that exposes private metadata before verification;
- support UI queries always apply the existing actor authorization boundary before returning decrypted data.

---

## 11. Failure Modes and Required Behavior

| Failure | Required behavior |
|---|---|
| No sellable events | Offer Help + Main menu; no dead end |
| WhatsApp sales disabled for selected event | Explain briefly + Help/Main menu |
| Invalid menu input | Repeat current actionable menu |
| Customer enters `0` from subflow | Safe main-menu recovery; preserve active Order |
| Customer enters old `#` command | Hidden compatibility main-menu recovery |
| Invalid resend email | Explain + ask email again + Main menu |
| No eligible tickets for email | Generic non-enumerating response + Help/Main menu |
| OTP invalid/expired | Retry prompt + Main menu |
| OTP locked/rate-limited | Explain safely + Help/Main menu |
| Exactly one eligible ticket | Bind one candidate and resend |
| 2–9 eligible tickets | Show one-ticket selection |
| >9 eligible tickets | Human support handoff; do not render unbounded list |
| Phone does not match Order | Do not reject; continue email-verified flow |
| Support case already active | Reuse existing active case; do not create duplicate |
| Two operators claim simultaneously | Exactly one succeeds via optimistic lock |
| Meta outbound retryable failure | Oban retry; operator sees pending/retry state |
| Meta auth/permanent failure | Mark failed, alert operator; do not claim sent |
| Human reply outside 24h window | Require approved template path |
| Customer sends sales-menu number during active support | Treat as support text except reserved global escape |
| Customer leaves support | Cancel case and safe main-menu recovery |
| Node/Redis loss | Rebuild mirrors; Postgres durable state remains authoritative |

---

## 12. Controlled WhatsApp E2E Test Event

### 12.1 Purpose

Create a repeatable production-like certification path for:

```text
WhatsApp inbound
→ menu navigation
→ event selection
→ offer selection
→ quantity
→ buyer data
→ checkout
→ Paystack test payment
→ payment confirmation
→ ticket issue
→ ticket delivery
→ resend identity
→ OTP
→ one-ticket selection
→ resend delivery
→ human support handoff/reply/resolve
```

### 12.2 Safety rules

- create the event through supported application/admin paths, not ad-hoc SQL;
- Paystack **must** be in test mode before the event sales gate is enabled;
- use the Meta test sender / allowlisted test recipients while certification is in progress;
- event starts with `whatsapp_sales_enabled=false`;
- explicitly enable only during a test window;
- disable immediately after certification;
- never reuse real customer orders/tickets for the certification matrix;
- clearly name/label the event as internal test data;
- no production customer should be able to discover or buy it after the public WhatsApp number is launched.

If the existing Event model cannot safely create an internal-only event without a real upstream Tickera source, implementation must stop and design an explicit supported fixture/admin path rather than bypassing invariants with direct DB inserts.

### 12.3 Minimum test inventory

The certification data must cover:

1. one Order / one eligible ticket;
2. one Order / multiple eligible tickets;
3. multiple Orders sharing the same email;
4. matching buyer phone and current WhatsApp number;
5. nonmatching buyer phone and current WhatsApp number;
6. mixed-case email input;
7. punctuation/capitalization variants in names for display/backward compatibility;
8. valid OTP;
9. invalid OTP;
10. expired OTP;
11. locked/rate-limited OTP;
12. support request before purchase;
13. support request while an active Order exists;
14. customer leaves support with `0`;
15. operator claim race;
16. operator reply success;
17. outbound failure surfaced to operator;
18. no-events behavior;
19. sales-disabled event behavior;
20. active-order main-menu recovery.

### 12.4 Certification terminal state

A test run is certified only when:

- checkout reaches a test-paid state;
- ticket issuance/delivery succeeds;
- resend verifies email ownership and returns exactly the selected ticket;
- human support can be requested, claimed, replied to, and resolved in the same WhatsApp thread;
- no path in the scripted matrix produces an actionless customer response;
- no raw PII/OTP/token appears in logs or Oban args;
- post-test event WhatsApp sales gate is disabled.

---

## 13. Recommended Folder and Naming Structure

```text
lib/fastcheck/messaging/whatsapp/
  conversation_state_machine.ex
  input_normalizer.ex
  menu_renderer.ex
  copy.ex
  resend_flow.ex
  support_router.ex

lib/fastcheck/tickets/resend/
  request.ex
  eligibility.ex
  otp.ex
  rate_limit.ex
  result.ex
  hash.ex

lib/fastcheck/support/
  support_case.ex
  support_message.ex
  support_queue.ex
  support_queue/server.ex
  policy_checks.ex

lib/fastcheck/workers/
  support_outbound_worker.ex

lib/fastcheck_web/live/support/
  inbox_live.ex
  case_live.ex

test/fastcheck/messaging/whatsapp/
test/fastcheck/tickets/resend/
test/fastcheck/support/
test/fastcheck/workers/
test/fastcheck_web/live/support/

docs/fastcheck_sales/runbooks/
  WHATSAPP_SUPPORT_OPERATIONS.md
  WHATSAPP_E2E_CERTIFICATION_EVENT.md
```

Naming rule: domain resources use business names (`SupportCase`, `SupportMessage`), adapters use channel-specific names (`WhatsApp.SupportRouter`), and infrastructure workers state their side effect (`SupportOutboundWorker`). Do not place support business rules inside LiveView or the webhook controller.

---

## 14. Delivery Sequence

Detailed implementation tasks belong in the later implementation plan. Architectural dependency order is:

### Phase A — Navigation contract

- remove main-menu Back;
- make `0` the advertised Main menu action in subflows;
- retain hidden `#` compatibility;
- ensure no-events/status/error responses remain actionable;
- preserve active-order guards.

### Phase B — Email-first resend

- replace name-first state with email-first state;
- move OTP verification before ticket selection;
- use phone/WA ID only as ranking/correlation;
- add bounded one-ticket selection;
- add normalized-email DB index;
- move resend rate limiting to the approved Redis ZSET architecture while retaining durable audit.

### Phase C — Human support domain

- SupportCase/SupportMessage resources and migrations;
- input routing boundary;
- customer support description + waiting lifecycle;
- encrypted support messages;
- optimistic claim/resolve actions;
- Redis/ETS/PubSub hot queue representation.

### Phase D — Operator support UI and delivery

- LiveView inbox;
- claim/case view;
- operator replies through Oban + existing WhatsApp client;
- Meta service-window/template guard;
- audit and failure presentation.

### Phase E — E2E certification event

- supported test-event creation;
- test offers/inventory;
- Paystack test checkout;
- scripted certification matrix;
- post-test disable/cleanup runbook.

Do not start Phase E by manually inserting production rows if the supported event setup path is incomplete.

---

## 15. Explicit Non-goals for This Programme

- AI support agent;
- FAQ/self-service decision tree;
- support categories A/B/C/D before human handoff;
- fuzzy name matching for resend;
- resend-all-tickets action;
- customer-facing ticket search by WhatsApp number alone;
- replacing existing Sales Order/payment state machines;
- replacing the existing WhatsApp webhook/dedupe pipeline;
- Redis ownership locks;
- a second dashboard authentication system;
- polling-based support inbox updates.

---

## 16. Success Criteria

The programme is complete when all of the following are true:

1. main menu has no Back option;
2. rendered customer navigation no longer advertises `#`;
3. `0` has one clear customer meaning: Main menu/leave current subflow;
4. hidden `#` compatibility still safely recovers legacy users;
5. every non-terminal customer response offers a clear next action/input;
6. resend starts with email, not name;
7. email is normalized case-insensitively as today;
8. WhatsApp phone improves correlation but cannot authenticate resend;
9. email OTP is verified before ticket metadata is disclosed/selected;
10. one candidate resends directly, multiple candidates require one-ticket selection;
11. typed name is not required for the normal resend path;
12. no fuzzy matching is introduced;
13. Help accepts one free-text description and creates a same-thread human support case;
14. active support suppresses normal bot state-machine execution;
15. an authorized operator can claim, reply, and resolve with realtime UI updates;
16. claim/resolve races are safely guarded;
17. plaintext support content and resend PII do not leak into logs/Oban/Redis;
18. all new critical DB query paths are indexed;
19. test event proves purchase → payment → issue → resend → support end-to-end using Paystack test mode;
20. the test event is disabled after certification.

---

## 17. Review Gate

This document is a design specification, not implementation authorization.

After written review/approval:

1. create a detailed implementation plan using TDD-first sequencing;
2. define migration compatibility for existing resend states;
3. define exact Ash actions/policies and optimistic-lock fields;
4. define exact Redis keys/TTLs/invalidation events;
5. define operator authorization mapping to the current dashboard actor model;
6. define the supported test-event provisioning path;
7. only then generate coding-agent execution prompts.

**STOP:** no production code, migrations, production data changes, test-event creation, or deployment before this written spec is approved and the implementation plan is reviewed.