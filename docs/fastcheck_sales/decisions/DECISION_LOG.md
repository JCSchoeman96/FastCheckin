# FastCheck Sales Decision Log

## Status

This log records accepted planning decisions for the VS-00 through VS-00D
planning gates. The implementation source documents are not rewritten by this
log; they remain read-only references.

## Source Documents

| Document | Version | Status |
|---|---|---|
| `FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md` | v0.2.3 HARDENED | Accepted as planning reference |
| `FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md` | v1.1.3 HARDENED | Accepted as planning reference |

## Decisions

| Decision | Value | Status | Rationale | Consequence |
|---|---|---|---|---|
| Primary production channel | `whatsapp_first_paid_core` | accepted | Product direction is WhatsApp-first through Meta Cloud API with Paystack-backed payment. | WhatsApp launch slices are required before production paid launch. |
| Secondary pre-launch paths | `internal_pilot_sales`, `admin_assisted_sales` | accepted | They let the team validate Sales core and support flows before public traffic. | Both paths must use the same Sales core and cannot bypass safety rules. |
| Public web checkout | `web_checkout_sales` | deferred | Web checkout is useful but must not become the default product direction before WhatsApp-first launch. | Web checkout can be planned later as a secondary channel. |
| Shared Sales core | all channels use one Sales core | accepted | Channel-specific business rules would fracture inventory, payment, ticket, and scanner safety. | WhatsApp, admin-assisted, internal pilot, and future web checkout use the same checkout/payment/issuance paths. |
| Access model | `event_scoped_first` | accepted | Existing FastCheck data is event-centered and the app does not yet have a real organization model. | Sales records and admin/operator access are scoped by event where applicable. |
| First-release owner boundary | `event_id` | accepted | Event scope is explicit enough to prevent broad global access while avoiding premature tenancy. | Later policy slices must include cross-event denial tests. |
| Organization tenancy | `organization_id` deferred | accepted | Adding `organization_id` without a real organization/membership model would create fake safety. | Docs and naming must leave room for a future tenant-isolation slice. |
| Implementation gates | `VS-01A+` blocked until `VS-00A` through `VS-00D` are accepted | accepted | Dangerous implementation requires explicit state, security, inventory, and launch contracts. | Coding agents must not start runtime work before gates are accepted. |
| Paystack authority | server-side verification required | accepted | Webhooks can duplicate, arrive late, or be spoofed without verification. | Paystack webhook payload alone never marks payment verified. |
| Inventory authority | Redis ReservationLedger required | accepted | Checkout needs atomic hot inventory to avoid oversell. | No channel may bypass `ReservationLedger`. |
| Ticket authority | backend issuance service required | accepted | Ticket creation must be idempotent and scanner-compatible. | No channel or webhook may issue tickets directly. |
| Scanner-safe revocation | required before paid launch | accepted | Refunded or revoked paid tickets must not remain scannable. | VS-15A is launch-critical. |

## Implementation Gate Rule

`VS-01A+`, including Ash resource work, migrations, Redis implementation,
Paystack integration, WhatsApp integration, ticket issuance, admin UI, and
scanner-visible changes, is blocked until the required VS-00 planning gates are
accepted.
