---
name: VS-01E Conversation Resource Skeleton
overview: Add the read-only Ash/Postgres Conversation skeleton with one additive migration, optional Order relationship wiring, RED/GREEN tests, slice documentation, and this canonical plan file without Meta, Redis, checkout, payment, ticket, delivery, scanner, or UI runtime behavior.
todos:
  - id: beads-branch
    content: "Verify Beads/Dolt, create/claim VS-01E bead; branch-only: git switch main && git pull origin main && git switch -c vs-01e-conversation-resource-skeleton"
    status: completed
  - id: red-tests
    content: "Write RED tests: update domain_shell + boundary tests; add conversation skeleton/migration tests + vs_01e_boundary_test"
    status: completed
  - id: migration
    content: "Add single migration *create_sales_conversations.exs with CHECK constraints including phone_e164 E.164 format, nullable sales_orders.sales_conversation_id, on_delete restrict FK, and named indexes"
    status: completed
  - id: ash-resource
    content: "Implement Conversation; register in FastCheck.Sales; add optional Order relationship; mark restricted fields sensitive?: true"
    status: completed
  - id: slice-docs
    content: "Add docs/fastcheck_sales/slices/VS-01E_CONVERSATION_RESOURCE_SKELETON.md"
    status: completed
  - id: verify
    content: "Run targeted Sales tests and mix precommit; close Bead with Dolt sync"
    status: completed
isProject: false
---

# VS-01E Conversation Resource Skeleton

## Plan metadata

| Field | Value |
|--------|--------|
| **Plan ID** | `VS-01E-conversation-resource-skeleton` |
| **Plan version** | `v1` |
| **Status** | Approved after reviewer feedback |
| **Scope** | VS-01E Conversation Resource Skeleton |
| **Authority** | This [`.cursor/plans/vs-01e-conversation-resource-skeleton.plan.md`](.cursor/plans/vs-01e-conversation-resource-skeleton.plan.md) file is the **active implementation contract** for VS-01E. The [VS-01E feature pack](docs/fastcheck_sales/feature_packs/0009_VS-01E_conversation-resource-skeleton/VS-01E-FEATURE_PACK.md) is the upstream planning source. [VS-01B](docs/fastcheck_sales/handoffs/VS-01B_IMPLEMENTATION_HANDOFF.md), [VS-01C](docs/fastcheck_sales/handoffs/VS-01C_IMPLEMENTATION_HANDOFF.md), and [VS-01D](docs/fastcheck_sales/handoffs/VS-01D_IMPLEMENTATION_HANDOFF.md) handoffs define merged implementation reality. On conflict, this plan wins for implementation sequencing and test ownership. |
| **Last updated** | 2026-06-15 |

### Revision log

- `v1` — initial VS-01E implementation plan based on VS-01D handoff, VS-01E feature pack, and reviewer-required changes.

### Canonical plan file

The `.cursor/plans/vs-01e-conversation-resource-skeleton.plan.md` file is intentionally committed in the VS-01E slice because it is the canonical active plan per repo plan governance.

- Do not create duplicate VS-01E plan files.
- Do not leave another active VS-01E plan unmarked.
- Do not use filename cloning for versioning; bump version inside this file only.

---

## Planning verdict

Slice Planning Report validated against the VS-01E feature pack, merged VS-01B/VS-01C/VS-01D code and handoffs, and accepted VS-00A through VS-00D decisions.

**Status: APPROVED after reviewer feedback.**

---

# Slice Planning Report — VS-01E Conversation Resource Skeleton

## Implementation contract

Implement exactly:

- `FastCheck.Sales.Conversation`
- `sales_conversations`
- nullable `sales_orders.sales_conversation_id`
- `Conversation has_many Orders`
- nullable `Order belongs_to Conversation`
- VS-01E resource, migration, and boundary tests
- VS-01E slice documentation
- this canonical Cursor plan file

Use one timestamped migration named `*_create_sales_conversations.exs`. The migration must create `sales_conversations`, add nullable `sales_orders.sales_conversation_id`, use `on_delete: :restrict`, and add `sales_conversations_phone_e164_format`:

```text
CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$')
```

## Strictly forbidden

- Meta/WhatsApp client
- webhook controller
- webhook signature verification
- Redis session/rate-limit logic
- checkout creation
- Paystack behavior
- ticket/delivery behavior
- Oban workers
- admin/customer UI
- scanner/attendee/event/mobile changes
- `organization_id`
- generic `update_status` / `update_state`
- workflow/menu transition actions
- raw WhatsApp payload storage

## Verification commands

- `mix deps.get`
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix ecto.migrate`
- `mix test test/fastcheck/sales/domain_shell_test.exs`
- `mix test test/fastcheck/sales/conversation_resource_skeleton_test.exs`
- `mix test test/fastcheck/sales/conversation_resource_migrations_test.exs`
- `mix test test/fastcheck/sales/vs_01e_boundary_test.exs`
- `mix test test/fastcheck/sales/`
- `mix precommit`
