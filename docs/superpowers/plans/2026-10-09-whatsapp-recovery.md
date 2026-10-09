# WhatsApp recovery implementation plan

> Implementation and review notes for the recovery-flow fix.

Goal: recover stale WhatsApp conversations without cancelling paid orders or creating duplicate active orders.

Architecture: navigation belongs to the existing conversation state machine and menu renderer. CheckoutExpiry owns customer cancellation under its existing per-order payment lock and releases holds through ReservationLedger. Authoritative payment uncertainty must prevent cancellation and a fresh purchase.

The user supplied the design and safety constraints. Work is tracked as FastCheckin-v35n in the primary checkout's Beads database. This T3 worktree matches origin/main at 77442e8.

- [x] Reproduce the exact support reply and failed `#` navigation in `conversation_state_machine_test.exs`. The reproduction fails because the conversation remains `manual_review`.
- [x] Add cancellation tests for unpaid cancellation, repeated requests, payment attempts, TicketIssue and Attendee records, ledger failures, protected order states, and verification racing cancellation. The race test pauses verification at the provider boundary, attempts cancellation, then completes successful verification.
- [x] Extend CheckoutExpiry with customer cancellation under the per-order advisory lock. Reload authoritative state, reject payment attempts and ticket artifacts, validate the hold, release through ReservationLedger, and transition Order and CheckoutSession. Refuse unresolved payments. Keep order mutation out of WhatsApp code.
- [x] Add state-aware recovery menus and an explicit cancellation confirmation. Preserve active order identity while clearing transient selections, recheck before cancellation, and keep duplicate-order guards.
- [x] Test terminal-state entry, help, protected order states, a fresh purchase after cancellation, stale cancellation choices, idempotent cancellation, and hold release.
- [x] Update the WhatsApp navigation contract. `bd dolt status` found the Dolt server, but the configured `FastCheckin` database is missing from this worktree, so `bd ready` and Beads updates could not run. The task is recorded as FastCheckin-v35n in the primary checkout.
- [x] Review the changes and run targeted tests plus `mix precommit` on an isolated test partition. The default test database still fails on the known duplicate `sync_logs_active_lease_expiry_index` migration. Do not delete or change database objects to work around it.
- [ ] Commit the reviewed changes, create a detailed PR, and link it to the T3 thread. Do not deploy or change production data.

Local test command:

```bash
set -a
source /home/jcschoeman96/.config/dev-core/project-db.env
set +a
MIX_TEST_PARTITION=whatsapp_recovery_v35n MIX_ENV=test mix test test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs
```

Use separate partition suffixes for test runs. The default workstation test database has an unrelated duplicate-index migration failure. No database objects should be deleted to work around it.
