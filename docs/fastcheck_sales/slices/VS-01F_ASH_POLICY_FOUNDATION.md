# VS-01F Ash Policy Foundation

## Scope

VS-01F adds the first Ash policy foundation across the existing FastCheck Sales
resource skeletons. It does not add workflows, provider integrations, Redis,
ticket issuance, delivery sending, admin UI, scanner changes, mobile API
changes, migrations, or new tables.

## Actor Model

Sales policies use explicit Ash actors with this shape:

```elixir
%{
  actor_type: :system | :admin | :operator | :customer_session,
  actor_id: optional,
  user_id: optional,
  allowed_event_ids: optional_list
}
```

`system` is for internal trusted jobs and future service orchestration.
`admin` can access event-scoped restricted support detail where a safe event
scope exists. `operator` is narrower than admin and is denied raw provider
payloads, token hashes, and sensitive PII fields by default.
`customer_session` cannot perform broad Sales reads.

## Event Scope

First release remains `event_scoped_first`; `organization_id` is still deferred.

Scoped resources:

- `TicketOffer` scopes by `event_id`.
- `Order` scopes by `event_id`.
- `OrderLine` scopes through `order.event_id`.
- `CheckoutSession` scopes through `order.event_id`.
- `PaymentAttempt` scopes through `order.event_id`.
- `TicketIssue` scopes through `order.event_id`.
- `DeliveryAttempt` scopes through `order.event_id`.

Resources without a reliable event scope path in this slice are system-only for
reads:

- `PaymentEvent`
- `StateTransition`
- `Conversation`

Later slices may add scoped actions or links for those resources. Until then,
admin/operator must not receive broad global reads.

## Restricted Fields

Field policies restrict raw provider payloads, provider URLs/codes, token hashes,
ticket identifiers, buyer PII, delivery recipient details, and WhatsApp
conversation identifiers/state from operator and customer-session access.

Customer-facing token values are not stored in plaintext by this slice.

## Deferred Work

This slice intentionally defers:

- checkout and payment workflows
- Paystack integration
- Redis reservation/inventory behavior
- WhatsApp/Meta integration
- ticket issuance
- delivery sending
- admin/customer UI
- manual review operations
- scanner/mobile changes
- organization tenancy

Future slices must extend these policies instead of bypassing them.
