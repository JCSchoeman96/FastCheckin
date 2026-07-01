# VS-24B — PDF Ticket Generation Feature Pack

Planning pack for `JCSchoeman96/FastCheckin` issue #439, based on merged VS-24A.

## Purpose

Implement server-side PDF ticket generation as a consumer of `FastCheck.Tickets.Artifact` / `ArtifactResolver`.

## Pack Contents

- `VS-24B-FEATURE_PACK.md` — full plan.
- `CODING_AGENT_PROMPT.md` — copy-paste implementation prompt.
- `TOON_PROMPTS.md` — granular single-task prompts.
- `pack.json` — machine-readable metadata.
- `POST_MERGE_HANDOFF_TEMPLATE.md` — template only; do not add handoff in the implementation PR.

## Non-Negotiables

- Use `0046_VS-24B_pdf-ticket-generation` unless a repo index script generates a different next number.
- Do not change secure ticket controller/template/router.
- Do not add public PDF routes or delivery integration.
- Do not change payment, ticket issuance, scanner, revocation, refund, WhatsApp, or delivery-token behavior.
- Do not create a handoff under `docs/fastcheck_sales/handoffs/` in the implementation PR.
