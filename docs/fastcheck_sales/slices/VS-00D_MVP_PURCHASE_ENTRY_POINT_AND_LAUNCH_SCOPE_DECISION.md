# VS-00D MVP Purchase Entry-Point and Launch Scope Decision

## Purpose

Lock the first production launch scope and channel authority model before Sales
implementation begins.

## Scope

In scope:

- Primary production launch scope.
- Secondary/build paths before first launch.
- Deferred public web checkout path.
- VS-05A secondary entry-point scope.
- Channel authority and anti-bypass rules.
- Launch-critical slice classification.
- Event-scoped-first access decision.
- Structured launch/channel decision log.

Out of scope:

- Elixir code.
- Ash resources.
- Migrations.
- Redis implementation.
- Paystack implementation.
- Meta/WhatsApp implementation.
- Web checkout UI.
- Admin checkout UI.
- Oban workers.
- Tests.
- Scanner changes.

## Locked Launch Scope

```text
primary_launch_scope: whatsapp_first_paid_core

secondary_paths_before_first_launch:
  - internal_pilot_sales
  - admin_assisted_sales

secondary_paths_after_first_launch:
  - web_checkout_sales
```

Public web checkout must not be included before the first WhatsApp-first
production launch. It may be planned as a later secondary channel only after the
shared Sales core, Paystack verification, ticket issuance, delivery audit,
scanner-safe revocation, and WhatsApp-first production path are stable.

## Locked Access Model

```text
access_model: event_scoped_first
required_first_release_owner_boundary: event_id
organization_id: deferred
```

Admin/operator access must be scoped by event permissions, not by role alone.

## Documents

- [Primary Channel and Multi-Channel Strategy](../product/PRIMARY_CHANNEL_AND_MULTI_CHANNEL_STRATEGY.md)
- [Selected Launch Scope](../product/SELECTED_LAUNCH_SCOPE.md)
- [Sales Channel Authority Model](../product/SALES_CHANNEL_AUTHORITY_MODEL.md)
- [Secondary Sales Paths](../product/SECONDARY_SALES_PATHS.md)
- [Sales Core Bridge MVP](../product/SALES_CORE_BRIDGE_MVP.md)
- [Launch Scope Test Requirements](../product/LAUNCH_SCOPE_TEST_REQUIREMENTS.md)
- [Launch Scope Runbook Requirements](../product/LAUNCH_SCOPE_RUNBOOK_REQUIREMENTS.md)
- [Channel Decision Log](../product/CHANNEL_DECISION_LOG.md)

## Completion Checklist

- [x] Lock `whatsapp_first_paid_core`.
- [x] Include `internal_pilot_sales` and `admin_assisted_sales` before first
  production launch.
- [x] Defer `web_checkout_sales`.
- [x] Define VS-05A as secondary Sales entry points only.
- [x] Map WhatsApp-first checkout to VS-17 through VS-20.
- [x] Require all channels to use the same Sales core.
- [x] Add full structured decision entries for every launch/channel decision.
- [x] Lock `event_scoped_first`.
- [x] Defer `organization_id`.

## RED Documentation Checks

VS-00D is not accepted if:

- Primary production channel is not `whatsapp_first_paid_core`.
- Secondary sales paths are not explicitly listed.
- Public web checkout is included before first WhatsApp-first production launch.
- VS-05A claims to implement WhatsApp-first checkout by itself.
- Any channel can bypass Redis inventory.
- Any channel can bypass Paystack server-side verification.
- Any channel can issue tickets directly.
- Any channel can bypass `DeliveryAttempt` audit.
- Any channel can bypass scanner-safe revocation.
- `event_scoped_first` access is not documented.
- `organization_id` is introduced for the first implementation wave.

## GREEN Documentation Checks

VS-00D is accepted when:

- Primary production channel is `whatsapp_first_paid_core`.
- Internal pilot and admin-assisted sales are before-launch paths.
- Public web checkout is deferred.
- VS-05A is scoped to secondary entry points only.
- WhatsApp-first entrypoint maps to VS-17, VS-18, VS-19, and VS-20.
- All channels must use the same Sales core.
- Channel decision log uses the full structured format.
- Event-scoped-first access is locked.
- No code/migrations/resources/scripts/workers/tests are added.

## Acceptance Criteria

- Product docs exist in allowed docs paths.
- Structured decisions are complete for every launch/channel decision.
- Channel authority and anti-bypass rules are explicit.
- Selected launch scope controls future tests and runbooks.
