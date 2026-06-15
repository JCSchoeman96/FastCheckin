# VS-01E Conversation Resource Skeleton

## Status

Implemented as an Ash/Postgres skeleton slice.

## Scope

VS-01E adds the durable checkpoint resource for future WhatsApp-first sales
conversation flows:

- `FastCheck.Sales.Conversation`
- `sales_conversations`
- nullable `sales_orders.sales_conversation_id`
- `Conversation has_many Orders`
- nullable `Order belongs_to Conversation`

Conversation remains optional. Existing secondary Sales paths and existing
orders do not require a conversation row.

## Access and Tenancy Decisions

- Access model: `event_scoped_first`.
- `organization_id`: deferred. VS-01E intentionally does not add an
  `organization_id` column.
- Ash policies are still deferred to VS-01F.

## Durable Fields

`sales_conversations` stores durable checkpoint data only:

- `phone_e164`
- `wa_id`
- `session_key`
- `rate_limit_key`
- `preferred_language`
- `locale`
- `state`
- `state_data`
- `last_inbound_message_id`
- `last_outbound_message_id`
- `last_message_at`
- `expires_at`
- `needs_human`
- `handoff_reason`
- timestamps

Sensitive/restricted Ash attributes are marked `sensitive?: true` where they
contain PII, provider identifiers, session key references, or recoverable
conversation data.

## Database Constraints and Indexes

The migration adds:

- conversation state CHECK constraint using the accepted VS-00A vocabulary
- preferred language CHECK constraint for `af` and `en`
- `sales_conversations_phone_e164_format`:
  `CHECK (phone_e164 ~ '^\\+[1-9][0-9]{7,14}$')`
- lookup and support queue indexes for phone, WhatsApp id, session key,
  human handoff, state/expiry, and recent message ordering
- nullable `sales_orders.sales_conversation_id` FK with `on_delete: :restrict`

There is no broad unique index on `phone_e164`, so historical conversations for
the same phone number remain allowed.

## Boundary

VS-01E does not implement:

- Meta/WhatsApp client
- webhook controller or signature verification
- Redis session/rate-limit logic
- conversation menu or workflow transition actions
- checkout creation
- Paystack behavior
- ticket issuing or delivery behavior
- Oban workers
- admin/customer UI
- scanner, attendee, event, Tickera, Android, or mobile API changes
- raw WhatsApp payload or message body storage

## Tests

VS-01E adds or updates tests for:

- exact Sales domain resource registration through VS-01E
- Conversation resource metadata, read/list actions, attributes, sensitive
  fields, and relationships
- `sales_conversations` columns, indexes, constraints, and optional order FK
- invalid non-E.164 phone rejection
- duplicate phone allowance
- forbidden runtime paths and workflow actions

Earlier migration tests remain subset-scoped per Option A. The VS-01E migration
test owns the full ten-table Sales inventory.
