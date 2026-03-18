# Scanner Feedback

## Current Runtime Goal

Feedback must reflect local queue capture and later server authority without
pretending that local capture equals server-confirmed admission.

**Post-B1 wording:** On accepted capture handoff, scanner copy is **“Queued locally (pending upload)”**.

## Current Runtime States

- captured and queued
- replay-suppressed locally
- upload pending
- upload completed with terminal server result
- auth expired / sync blocked

## Direction

Current UI and runtime flows expose only `IN`.

`OUT` remains a future-capable domain value but is not selectable or operational
in the current scanner UI.

## Feedback Constraint

Because the current mobile API response is still message-shaped, the UI must
distinguish:

- local queue acceptance
- terminal server result

It must not imply richer local approval logic than the backend currently
supports.

## Terminal errors (post-B1)

Do not parse message text to infer “invalid / not found”. If a flush outcome is a terminal error without a stable structured code, treat it as the generic **Rejected by server**.
