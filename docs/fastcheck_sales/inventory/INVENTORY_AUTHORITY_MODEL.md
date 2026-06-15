# Inventory Authority Model

## Hot, Warm, And Cold Data

| Data | Layer | Notes |
|---|---|---|
| Active availability counter | Redis hot | Used by checkout, WhatsApp, web/admin availability display. |
| Active holds | Redis hot | Hash/zset pattern with TTL/expiry ledger. |
| Order/checkout intent | Postgres/Ash durable | Never immediate flash-sale counter. |
| Configured offer inventory | Postgres/Ash durable | Source for initialization and reconciliation. |
| Offer display cache | Cachex/Redis warm | Cachex 1-5 min or Redis 30 min when implemented. |
| Payment/webhook dedupe | Redis warm/hot plus Postgres durable event | SETNX-style dedupe plus unique DB identity. |
| Real-time availability updates | Phoenix PubSub/LiveView push | Avoid polling loops for active dashboards. |
| Analytics/occupancy summaries | Redis/materialized/cached aggregate | Avoid large table scans during peak. |

## Planned Inventory-Facing Fields

Future implementation may use these planned fields:

- `TicketOffer.event_id`
- `TicketOffer.configured_quantity_available`
- `TicketOffer.initial_quantity`
- `TicketOffer.sales_enabled`
- `TicketOffer.starts_at`
- `TicketOffer.ends_at`
- `TicketOffer.lock_version`
- `Order.public_reference`
- `Order.event_id`
- `Order.source_channel`
- `CheckoutSession.redis_hold_key`
- `CheckoutSession.hold_token`
- `CheckoutSession.hold_quantity`
- `CheckoutSession.expires_at`
- `TicketIssue.scanner_status`

This contract documents how those fields interact with Redis. It does not
implement the fields.
