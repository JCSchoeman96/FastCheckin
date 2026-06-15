# Secondary Sales Paths

## Internal Pilot Sales

Status:

```text
accepted_as_testing_bridge
```

Internal pilot sales are allowed for validating Sales core, Paystack integration,
ticket issuance, scanner acceptance, support operations, and runbooks before
public traffic.

Restrictions:

- Not a public paid event channel.
- Must use the same Sales core.
- Must use Redis inventory unless explicitly documented as a non-inventory test
  fixture.
- Must not bypass ticket issuance idempotency.

## Admin-Assisted Sales

Status:

```text
accepted_as_secondary
```

Operators/admins may create checkout links/orders for customers as a controlled
secondary path.

Restrictions:

- Must not bypass Redis inventory.
- Must not mark orders paid manually without audited manual-review policy.
- Must not issue tickets directly.
- Must use `StateTransition` audit.
- Must use event-scoped access and PII masking.

## Public Web Checkout Sales

Status:

```text
deferred
```

Public/customer-facing web checkout is a future secondary channel only. It must
not become the default first production product direction.
