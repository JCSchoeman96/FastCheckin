# Inventory Health and Launch Gates

## Health States

| State | Meaning | Checkout behavior |
|---|---|---|
| `healthy` | Redis hot state is initialized and reconciled. | Reservations allowed if offer policy allows. |
| `rebuilding` | Reconciliation/rebuild is running. | New reservations denied. |
| `degraded` | Inconsistency or partial failure detected. | New reservations denied; support/manual review path. |
| `closed` | Sales intentionally closed. | New reservations denied. |

## Launch Gates

Before opening paid sales:

- Redis reachable.
- Offer metadata initialized.
- Availability counter initialized.
- Health state is `healthy`.
- No unresolved reconciliation anomalies.
- Source docs and VS-00 planning gates accepted.
- Payment-after-expiry behavior accepted.
- Scanner-safe revocation is planned before paid launch.

## Operational Rules

- Unknown health is treated as unsafe.
- Degraded health blocks all channels.
- Admin-assisted sales cannot bypass degraded inventory.
- Internal pilot can use fixtures only if explicitly documented as non-public and
  non-inventory-affecting.
