# FastCheck Sales Planning Gates

This directory contains the accepted planning contracts for the FastCheck Sales
roadmap. The source documents remain read-only references:

- `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`
- `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`

The VS-00 through VS-00D work is a docs-only planning-gate exception. It groups
five mutually dependent planning slices so later coding agents can implement
runtime work without inventing missing product, security, state, or inventory
rules.

## Implementation Block

Implementation slices remain blocked until these planning gates are accepted:

- `VS-00` planning baseline
- `VS-00A` state-machine and failure-policy contracts
- `VS-00B` security, PII, and token policy contracts
- `VS-00C` inventory recovery and reconciliation contracts
- `VS-00D` launch scope and channel decisions

No `VS-01A+` implementation work may begin before the required gate documents
are reviewed and accepted.

## Accepted Direction

- Primary production launch scope: `whatsapp_first_paid_core`
- Pre-launch secondary/build paths: `internal_pilot_sales`,
  `admin_assisted_sales`
- Deferred secondary path: `web_checkout_sales`
- First-release access model: `event_scoped_first`
- First-release owner boundary: `event_id`
- Deferred tenant field: `organization_id`

## Planning Gate Index

- [VS-00 Planning Pack Finalization](slices/VS-00_PLANNING_PACK_FINALIZATION.md)
- [VS-00A State Machine and Failure Policy Finalization](slices/VS-00A_STATE_MACHINE_AND_FAILURE_POLICY_FINALIZATION.md)
- [VS-00B Security, PII, and Token Policy Finalization](slices/VS-00B_SECURITY_PII_AND_TOKEN_POLICY_FINALIZATION.md)
- [VS-00C Inventory Recovery and Reconciliation Contract](slices/VS-00C_INVENTORY_RECOVERY_AND_RECONCILIATION_CONTRACT.md)
- [VS-00D MVP Purchase Entry-Point and Launch Scope Decision](slices/VS-00D_MVP_PURCHASE_ENTRY_POINT_AND_LAUNCH_SCOPE_DECISION.md)

## Supporting Docs

- [Decision Log](decisions/DECISION_LOG.md)
- [Risk Register](risks/RISK_REGISTER.md)
- [State Machine Master](state_machines/STATE_MACHINE_MASTER.md)
- [Security Master](security/SECURITY_PII_TOKEN_MASTER.md)
- [Inventory Master Contract](inventory/INVENTORY_MASTER_CONTRACT.md)
- [Selected Launch Scope](product/SELECTED_LAUNCH_SCOPE.md)
- [Channel Decision Log](product/CHANNEL_DECISION_LOG.md)

## Runtime Boundary

These docs define contracts only. They do not implement Ash resources,
migrations, Redis scripts, Paystack behavior, Meta/WhatsApp behavior, LiveView
surfaces, tests, Android scanner behavior, or mobile API changes.
