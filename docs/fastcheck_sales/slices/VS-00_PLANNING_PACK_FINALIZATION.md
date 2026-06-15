# VS-00 Planning Pack Finalization

## Purpose

Finalize the planning baseline for FastCheck Sales before dangerous
implementation begins. This slice confirms source documents, records decisions,
creates the risk register, and marks implementation gate dependencies.

## Scope

In scope:

- Confirm source docs by name and version.
- Record WhatsApp-first strategy.
- Record secondary channel policy.
- Record implementation gate dependencies.
- Record P0 risk register entries.
- Mark `VS-01A+` blocked until `VS-00A`, `VS-00B`, `VS-00C`, and `VS-00D`
  are accepted.

Out of scope:

- Elixir code.
- Ash resources.
- Migrations.
- Redis scripts.
- Paystack or Meta/WhatsApp implementation.
- LiveView/admin UI.
- Tests.
- Android scanner or mobile API changes.
- Rewriting `SOURCE_DOCS`.

## Accepted Baseline

FastCheck Sales is multi-channel, but WhatsApp is first. The first production
paid launch is `whatsapp_first_paid_core`.

Secondary/build paths before first launch:

- `internal_pilot_sales`
- `admin_assisted_sales`

Deferred secondary path:

- `web_checkout_sales`

All channels must use the same Sales core:

- Redis `ReservationLedger`
- Paystack server-side verification
- idempotent ticket issuance
- `DeliveryAttempt` audit
- `StateTransition` audit
- scanner-safe revocation
- PII and log-redaction policy

## Source Documents

- `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`
- `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`

These are read-only references for this planning-gate exception.

## Implementation Blockers

Implementation work in `VS-01A+` is blocked until these planning gates are
accepted:

- `VS-00A`: state machines and failure policies
- `VS-00B`: security, PII, and token policies
- `VS-00C`: inventory recovery and reconciliation contracts
- `VS-00D`: launch scope and channel decisions

Forbidden before gate acceptance:

- Ash installation or Sales resources
- migrations
- Redis mutation or Lua
- Paystack transaction integration
- Paystack webhook ingestion
- Meta/WhatsApp webhook or outbound integration
- ticket issuance implementation
- admin/manual operation UI
- scanner-visible revocation changes

## Completion Checklist

- [x] Confirm source docs by name/version without rewriting them.
- [x] Record WhatsApp-first strategy.
- [x] Record secondary channel policy.
- [x] Record implementation gate dependencies.
- [x] Record risk register P0 entries.
- [x] Mark `VS-01A+` blocked until `VS-00A`, `VS-00B`, `VS-00C`, and `VS-00D`
  are accepted.

## RED Documentation Checks

This slice is not accepted if:

- The primary production channel is not explicitly WhatsApp-first.
- Secondary web/admin/internal paths are not classified.
- The decision log is missing.
- The risk register is missing.
- `VS-01A+` is not blocked behind planning gates.
- Any channel is allowed to own payment, inventory, ticket issuance, or scanner
  validity.
- Paystack webhook payload alone can be payment authority.
- Redis inventory contract is not required before checkout.
- Scanner-safe revocation is not required before paid launch.

## GREEN Documentation Checks

This slice is accepted when:

- The roadmap baseline names `whatsapp_first_paid_core`.
- Internal pilot and admin-assisted sales are allowed as controlled pre-launch
  paths.
- `web_checkout_sales` is deferred.
- `DECISION_LOG.md` records all VS-00 decisions.
- `RISK_REGISTER.md` includes P0 architecture risks.
- `VS-00A`, `VS-00B`, `VS-00C`, and `VS-00D` are marked as required gates.
- `VS-01A+` implementation slices are blocked until required gates are accepted.
- No source doc or runtime path is rewritten.

## Acceptance Criteria

- VS-00 planning docs exist in allowed docs paths.
- The source docs are referenced, not modified.
- The decision log and risk register are created.
- The implementation gate is explicit and searchable.
- No runtime behavior is changed.
