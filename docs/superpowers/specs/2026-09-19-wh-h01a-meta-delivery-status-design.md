# WH-H01A Meta delivery-status reconciliation

## Goal

Turn signed, scope-filtered Meta WhatsApp status callbacks into durable provider evidence and a monotonic `DeliveryAttempt` projection. The callback path must not send messages or replay sales business logic.

## Boundaries

The controller keeps this order:

1. Validate runtime WhatsApp configuration.
2. Verify `x-hub-signature-256` against the raw request body.
3. Decode JSON.
4. Filter entries and changes through `WebhookScope.filter/2`, which requires the configured WABA and phone number ID.
5. Normalize and reconcile statuses from the scoped payload.
6. Normalize and process message commands from the same scoped payload.

Status events do not enter `InboundCheckpoint`, `ConversationStateMachine`, checkout, payment, ticket, inventory, or scanner code. A mixed payload can produce both status evidence and an inbound message job.

## ProviderStatus

`FastCheck.Messaging.WhatsApp.ProviderStatus` is a transport value object with these fields:

- `provider`
- `provider_message_id`
- `status`
- `provider_timestamp`
- `provider_error_code`
- `raw_payload_hash`
- `correlation_id`

Normalization accepts only Meta status values `sent`, `delivered`, `read`, `failed`, and `deleted`. WAMIDs are capped at 256 bytes. Error codes are limited to 64 safe ASCII characters or decimal integers. Timestamps accept positive Unix seconds as integers or strings and become second-truncated UTC `DateTime` values. Correlation IDs are capped and restricted to safe characters. `Inspect` exposes only a hashed WAMID and bounded metadata.

## Reconciliation transaction

`FastCheck.Messaging.WhatsApp.DeliveryStatusReconciler.reconcile/1` runs one Postgres transaction for each normalized event.

The transaction performs an exact lookup on `provider = 'meta'`, `channel = 'whatsapp'`, and the WAMID. It locks the matching attempt row. Zero rows returns `{:ignored, :unknown_wamid}` without writing anything. More than one row rolls back with `:ambiguous_provider_message_id`; it never chooses a row.

For one row, it inserts `sales_delivery_status_events` with the provider, channel, WAMID, normalized status and timestamp, bounded error code, raw payload hash, correlation ID, and timestamps. The existing unique identity is the duplicate boundary. `on_conflict: :nothing` returns a duplicate result and never changes the projection. Evidence is never updated or deleted.

After a new evidence insert, the reconciler classifies the event using provider status rank and provider timestamp. Projection writes use Ash actions on the locked, reloaded `DeliveryAttempt` record, so `lock_version` and lifecycle validations remain active. An Ash failure rolls back the evidence insert.

Success states advance only in this order: `provider_accepted`, `sent`, `delivered`, `read`. Meta may skip states. Older or lower-ranked callbacks add evidence but do not regress the projection.

`mark_provider_failed` is a new lifecycle action for explicit Meta failure. It is separate from the existing local `mark_failed` action. Failure evidence advances an in-flight provider-accepted or sent attempt only when its timestamp is not older than the current provider evidence. A later failure after delivered or read, or a later success after failed, calls the existing manual-review lifecycle action and records the incoming provider status fields. `deleted` inserts evidence and leaves the projection unchanged. Manual-review and other terminal projections keep receiving immutable evidence while their projection remains unchanged.

## Tests

Tests cover value-object normalization and redaction; success progression and skipped callbacks; provider failure; duplicate evidence identity; out-of-order evidence; both contradiction directions; deleted observation; unknown and ambiguous WAMIDs; optimistic-lock-safe lifecycle updates; raw payload hash persistence; H03 WABA and phone filtering; invalid signatures; mixed status and message payloads; and the absence of payment, order, ticket, inventory, or conversation mutations.

## Scaling and operations

The callback path stays Postgres-backed. It performs one indexed WAMID lookup, one evidence insert, and at most one lifecycle projection update. It adds no Redis key, cache entry, PubSub event, GenServer authority, or Oban job. Logs contain status names, result atoms, correlation IDs, and hashed WAMIDs, never raw protected payloads.
