---
name: PR 304-307 brutal review
overview: "In-depth critique of the four-PR stack; v3 tightens #304 merge bar (small vs large events) and #305 parallel-limit doc wording."
todos:
  - id: fix-304-batch-inserts
    content: "#304 — Batch invalidation inserts / remove per-row Repo.insert pattern (small/modest events: mergeable with clearly opened follow-up; large-event confidence: prefer fix before merge)"
    status: pending
  - id: fix-306-copy
    content: "#306 — Fix duplicate 'Ticket not found' message in RedisStore db_gate_result"
    status: pending
  - id: fix-305-docs
    content: "#305 — Docs: exact 400 codes + client catch-up loop + one exact sentence — limit applies in parallel; attendees and invalidations are independently capped (same numeric limit)"
    status: pending
  - id: followup-305-txn-reads
    content: "Follow-up — Decide single-transaction reads for GET attendees+invalidations+version (stronger snapshot consistency)"
    status: pending
  - id: followup-307-apply-order-test
    content: "Follow-up — One explicit Android test for invalidations-before-upserts invariant + doc line"
    status: pending
  - id: followup-version-bump-optimization
    content: "Follow-up — Revisit conditional event_sync_version bumps only if client churn becomes visible"
    status: pending
isProject: false
---

# Brutal PR review: #304 → #307

- **Plan ID:** `pr-304-307-brutal-review`
- **Plan version:** `v3`
- **Status:** stakeholder-aligned review artifact (not implementation backlog by itself)
- **Last updated:** 2026-04-12
- **Change summary (v3):** Firmer #304 guidance (small/modest vs large-event merge bar); #305 docs checklist adds explicit parallel-limit / independent-cap sentence.

### Revision log

- `v1` — Initial brutal review (method, per-PR critique, summary table).
- `v2` — Stakeholder feedback: strongest agreement (#304 inserts, #305 multi-query edge, #306 DB gate, #307 dependency note); partial agreement on version bump / ReasonCodes / #307 apply order; added missed #305 limit-sharing decision and #304 transaction-weight framing; explicit fix-now vs follow-up list.
- `v3` — Stakeholder tweak: #304 merge bar stated plainly (modest events + follow-up OK; large-event confidence prefers fix pre-merge); #305 docs must spell out parallel `limit` and independent caps in one exact sentence.

---

## Stakeholder alignment (what landed)

**Strong agreement**

1. **#304 — Per-row invalidation inserts** are the **strongest** finding: real scale/latency risk for large reconcile drops, not theory. **Merge bar (say it plainly):** for **small/modest events**, mergeable **with a clearly opened follow-up** (not a vague someday ticket). For **large-event confidence**, **better to fix before merge** — same code path that bites is the heavy reconcile transaction, not insert count alone.
2. **#305 — Multi-query consistency** is a **valid** sharp edge (separate reads for invalidations, attendees, version): rare interleaving under concurrent reconcile; acceptable at likely scale; still **real**, not nitpicking.
3. **#306 — DB gate** is correctly praised: authority before Redis/Lua, snapshot excludes `not_scannable`, correctness does **not** depend on perfect Redis invalidation timing — strong architectural improvement.
4. **#307 — Dependencies:** #305 is the **contract** dependency; #306 is **operational stack** / Kotlin does not need it logically; linearity helps ops; reviewer confusion is a **fair, minor** criticism.

**Partial agreement (reprioritized)**

- **Incremental `event_sync_version` bump “noise”:** Valid trade-off point, but **lower priority** than the original review implied. Simplicity + safety + determinism weigh heavily; conditional bumps add subtlety — treat as **optimization / revisit if churn shows up**, not a near-term defect.
- **`ReasonCodes` as a thin module:** True but **low energy**; pattern + avoiding scattered strings is enough for now.
- **#307 invalidations-before-upserts:** Worth an **invariant + doc + test**, not framed as a major bug — **right move** per stakeholder.

**Gaps the first review should have stressed more**

1. **#305 — `limit` semantics (hard decision):** Implementation uses **parallel caps**: **`limit` is applied in parallel** — the **attendees** stream and the **invalidations** stream are **independently capped** (same numeric `limit` each). Future client work can still misread this even after reading the catch-up loop; docs need **one exact sentence** with that wording so nobody assumes a single shared budget across both sub-streams.
2. **#304 — Transaction weight, not only insert round-trips:** The deeper operational story is **long transaction duration** — lock span and **total work** inside one sync transaction during large reconciles. Batch inserts are the main **symptom fix**, but the **narrative** is “heavy reconcile txn,” not only N+1.

---

## Original review content (condensed)

**Method:** GitHub PR metadata + `gh pr diff`. Local [`sync_controller.ex`](lib/fastcheck_web/controllers/mobile/sync_controller.ex) may still be pre-#305.

**Verdict:** Stack is **coherent**: authoritative reconciliation, append-only invalidations, active-only sync-down, Redis gated by Postgres, Android loop aligned with [`docs/mobile_runtime_truth.md`](docs/mobile_runtime_truth.md).

**Cross-cutting strengths:** Merge order; two-checkpoint pagination vs [attendee-reconciliation plan](attendee-reconciliation-and-invalidation.plan.md); #306 DbAuthority + snapshot filter.

**Other sharp edges (unchanged):** Multi-query GET without single snapshot; cosmetic #305 title vs commit scope; [`Scan.check_in`](lib/fastcheck/attendees/scan.ex) logging for `not_scannable` (metrics/product); reactivation vs historical invalidation rows for support tooling.

---

## Fix or track immediately (owner list)

| Item | Action |
|------|--------|
| **#304** | Batch invalidation inserts / eliminate per-row insert pattern. **Small/modest events:** merge OK with a **written** follow-up issue. **Large events / revoke-heavy reconciles:** **prefer fix before merge** (or treat as release gate). |
| **#306** | Fix **"Ticket not found: Ticket not found"** copy |
| **#305** | [`docs/mobile_runtime_truth.md`](docs/mobile_runtime_truth.md): **exact** 400 `error` codes + **exact** client catch-up loop **and** one sentence: **`limit` applies in parallel — attendees and invalidations are independently capped** (same numeric limit per stream, not one shared pool). |

## Good follow-up, not blocker

- Decide **single-transaction reads** for #305 for stronger snapshot consistency.
- **Android:** one **explicit test** (and doc line) for **apply order** — invalidations then attendee upserts for a page.
- **Revisit** conditional `event_sync_version` bumps **if** client churn becomes visible.

---

## Per-PR pointers (unchanged skeleton)

- **#304:** Outer txn pattern + `replace_all_except` preserve eligibility — good. Risks: batch inserts + **txn weight** on large reconciles.
- **#305:** Parallel `limit` — **independent caps** per sub-stream; document ruthlessly (see exact sentence above); multi-query edge — optional txn later.
- **#306:** Idempotency fast path + DbAuthority + copy fix for not_found.
- **#307:** Room + loop + normalize tombstones; stack confusion optional note for reviewers.

---

## PR titles vs commits

Low value unless changelog automation cares — align `feat(mobile):` vs `feat(mobile API):` only if needed.

---

## Summary table (updated)

| PR | Ship stance | Top risk / follow-up |
|----|-------------|----------------------|
| #304 | Yes; **large-event bar: fix or gate** | Insert batching + **txn duration** on big reconciles |
| #305 | Yes | **Parallel limit / independent caps** (exact sentence in docs); 400 codes + catch-up loop; optional txn reads later |
| #306 | Yes | Copy fix; metadata parity comment |
| #307 | Yes | Apply-order test + doc; reviewer stack note optional |

**Blockers:** None mandatory from review alone. **#304** is the only item that changes the **merge vs fix-first** bar by deployment shape: **modest events** can ship with a **tracked** batch-insert follow-up; **large-event / revoke-heavy** confidence should **fix first** or explicitly accept txn risk.
