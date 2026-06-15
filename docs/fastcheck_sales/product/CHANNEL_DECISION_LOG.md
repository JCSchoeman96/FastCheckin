# Channel Decision Log

## Required Decision Format

Every launch/channel decision uses:

```text
decision name
decision value
decision status
rationale
accepted trade-offs
rejected alternatives
required roadmap effect
slices affected
security effect
inventory effect
payment effect
ticket issuance effect
scanner/sync effect
test requirements
runbook requirements
owner/reviewer
```

## Primary Production Launch Scope

| Field | Value |
|---|---|
| decision name | Primary production launch scope |
| decision value | `whatsapp_first_paid_core` |
| decision status | `accepted` |
| rationale | Product direction is WhatsApp-first through Meta Cloud API with Paystack payment and FastCheck backend authority. |
| accepted trade-offs | Production launch depends on WhatsApp slices and runbooks; web checkout waits. |
| rejected alternatives | `web_checkout_sales` as primary launch; channel-specific sales workflows. |
| required roadmap effect | VS-16 through VS-20 and final WhatsApp runbooks are launch-critical. |
| slices affected | VS-00D, VS-16, VS-17, VS-18, VS-19, VS-20, VS-22, VS-23C |
| security effect | WhatsApp identifiers/message content are sensitive; WhatsApp cannot own security authority. |
| inventory effect | WhatsApp checkout must use `ReservationLedger`. |
| payment effect | WhatsApp payment flow must use Paystack server-side verification. |
| ticket issuance effect | Tickets issue only through approved backend issuer. |
| scanner/sync effect | Scanner validity remains existing FastCheck backend/scanner path. |
| test requirements | E2E tests cover WhatsApp order, payment, ticket, delivery, and revocation. |
| runbook requirements | WhatsApp launch, payment pending, delivery window, and support runbooks. |
| owner/reviewer | Product owner and technical lead |

## Internal Pilot Sales

| Field | Value |
|---|---|
| decision name | Internal pilot sales |
| decision value | `internal_pilot_sales` |
| decision status | `accepted_as_testing_bridge` |
| rationale | Internal pilot validates Sales core before public traffic. |
| accepted trade-offs | Pilot-only affordances may exist but cannot become public bypass paths. |
| rejected alternatives | No pre-launch validation path; public launch as first real exercise. |
| required roadmap effect | Include internal pilot support in VS-05A or equivalent bridge work. |
| slices affected | VS-00D, VS-05A, VS-06B, VS-07C, VS-09D, VS-15A, VS-22 |
| security effect | Must follow event-scoped access and PII/log-redaction policy. |
| inventory effect | Uses `ReservationLedger` unless explicitly documented as non-inventory fixture. |
| payment effect | Uses Paystack sandbox/live rules appropriate to environment. |
| ticket issuance effect | Uses idempotent issuer; no direct ticket creation. |
| scanner/sync effect | Must prove scanner-compatible attendee/ticket outcomes. |
| test requirements | Tests cover pilot-created order through payment/issuance/scanner acceptance. |
| runbook requirements | Pilot setup, rollback, support, and incident notes. |
| owner/reviewer | Product owner and technical lead |

## Admin-Assisted Sales

| Field | Value |
|---|---|
| decision name | Admin-assisted sales |
| decision value | `admin_assisted_sales` |
| decision status | `accepted_as_secondary` |
| rationale | Admin-assisted checkout helps support controlled sales before public traffic. |
| accepted trade-offs | Adds admin/support surface earlier, with stricter audit and event scoping. |
| rejected alternatives | Admin marking paid or issuing tickets manually; role-only admin access. |
| required roadmap effect | VS-05A may include admin-assisted checkout link creation. |
| slices affected | VS-00B, VS-00D, VS-05A, VS-12, VS-13, VS-15B |
| security effect | Admin/operator display masking and event-scoped permissions required. |
| inventory effect | Must use `ReservationLedger`; no inventory bypass. |
| payment effect | Must use Paystack initialization and server-side verification. |
| ticket issuance effect | Must issue only through backend issuer. |
| scanner/sync effect | Revocation/refund must be scanner-visible. |
| test requirements | Admin-assisted flow tests include event-scoped access and audit. |
| runbook requirements | Admin-assisted checkout, manual review, refund/revocation runbooks. |
| owner/reviewer | Product owner and technical lead |

## Public Web Checkout

| Field | Value |
|---|---|
| decision name | Public web checkout |
| decision value | `web_checkout_sales` |
| decision status | `deferred` |
| rationale | Web checkout is a valid secondary path but must not precede WhatsApp-first production launch. |
| accepted trade-offs | Web checkout delivery waits until shared Sales core and WhatsApp-first path are stable. |
| rejected alternatives | Generic web checkout as first production product; web checkout hidden inside VS-05A before launch. |
| required roadmap effect | Web checkout is not included before first production launch. |
| slices affected | VS-00D, VS-05A, VS-22, future web checkout slice |
| security effect | Future web checkout must inherit PII/token/session policy. |
| inventory effect | Future web checkout must use `ReservationLedger`. |
| payment effect | Future web checkout must use Paystack server-side verification. |
| ticket issuance effect | Future web checkout must use backend issuer. |
| scanner/sync effect | Future web checkout tickets must support scanner-safe revocation. |
| test requirements | Deferred tests added when web checkout is pulled forward. |
| runbook requirements | Deferred public web checkout runbooks. |
| owner/reviewer | Product owner and technical lead |

## VS-05A Scope

| Field | Value |
|---|---|
| decision name | VS-05A scope |
| decision value | `secondary_sales_entry_points_only` |
| decision status | `accepted` |
| rationale | VS-05A should expose secondary entry points over the Sales core, not implement WhatsApp-first checkout. |
| accepted trade-offs | Secondary entry points may arrive before WhatsApp UI but remain bridge/support paths. |
| rejected alternatives | VS-05A as generic public web checkout; VS-05A as WhatsApp checkout. |
| required roadmap effect | WhatsApp checkout remains VS-17 through VS-20. |
| slices affected | VS-00D, VS-05A, VS-17, VS-18, VS-19, VS-20 |
| security effect | Secondary entry points follow event-scoped security and masking. |
| inventory effect | Secondary entry points use `ReservationLedger`. |
| payment effect | Secondary entry points use Paystack initialization/verification. |
| ticket issuance effect | Secondary entry points do not issue tickets directly. |
| scanner/sync effect | Secondary entry point tickets follow scanner-safe paths. |
| test requirements | VS-05A tests prove no bypass and correct source attribution. |
| runbook requirements | Secondary entry-point support runbooks. |
| owner/reviewer | Product owner and technical lead |

## Channel Authority

| Field | Value |
|---|---|
| decision name | Channel authority |
| decision value | `all_channels_use_same_sales_core` |
| decision status | `accepted` |
| rationale | Channel-specific business logic would break payment, inventory, ticket, and scanner safety. |
| accepted trade-offs | Channels may need adapters, but authority remains centralized. |
| rejected alternatives | WhatsApp-owned checkout logic; admin bypasses; direct channel ticket issuance. |
| required roadmap effect | Provider/client slices call core services rather than owning transitions. |
| slices affected | VS-05, VS-05A, VS-16, VS-17, VS-18, VS-19, VS-20 |
| security effect | Shared PII/token/log policy applies to every channel. |
| inventory effect | Shared `ReservationLedger` applies to every channel. |
| payment effect | Shared Paystack verification applies to every channel. |
| ticket issuance effect | Shared issuer applies to every channel. |
| scanner/sync effect | Existing scanner-compatible attendee path remains authority. |
| test requirements | Tests prove each selected source channel uses shared core boundaries. |
| runbook requirements | Runbooks describe channel adapters and shared core operations separately. |
| owner/reviewer | Product owner and technical lead |

## Tenant/Event Access

| Field | Value |
|---|---|
| decision name | Tenant/event access |
| decision value | `event_scoped_first` |
| decision status | `accepted` |
| rationale | Current FastCheck is event-centered; adding `organization_id` now would require a full tenant model that does not yet exist. |
| accepted trade-offs | Event-scoped access is explicit now; organization-level tenancy is deferred. |
| rejected alternatives | Global single-tenant access; premature `organization_id` without membership/policy model. |
| required roadmap effect | VS-01F and admin/operator slices require event-scoped allow/deny tests. |
| slices affected | VS-00B, VS-00D, VS-01F, VS-12, VS-13, VS-15B |
| security effect | Admin/operator access is scoped by event permission, not role alone. |
| inventory effect | Inventory records and offer operations remain event-aware through offer/event ownership. |
| payment effect | Payment/order lookup must be event/channel-safe and not globally unscoped. |
| ticket issuance effect | Ticket issuance links to event-owned order/offer facts. |
| scanner/sync effect | Scanner-visible updates remain event-scoped. |
| test requirements | Cross-event denial tests for list/read/manual actions before acceptance. |
| runbook requirements | Support runbooks must include event-scoped lookup and escalation. |
| owner/reviewer | Product owner and technical lead |
