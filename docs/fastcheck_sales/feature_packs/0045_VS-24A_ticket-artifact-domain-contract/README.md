# VS-24A Ticket Artifact Domain Contract — Patched Downloadable Feature Pack

Give this folder/ZIP to the coding agent.

## Files

| File | Purpose |
|---|---|
| `VS-24A-FEATURE_PACK.md` | Full planning pack and implementation contract. |
| `CODING_AGENT_PROMPT.md` | Copy-paste prompt for the coding agent. |
| `TOON_PROMPTS.md` | TOON scaffolding and granular micro-prompts. |
| `POST_MERGE_HANDOFF_TEMPLATE.md` | Template only; do not add handoff docs in the implementation PR. |
| `pack.json` | Machine-readable pack metadata. |

## Critical Patches Applied

- Pack folder uses `0045_VS-24A_ticket-artifact-domain-contract`, not `0044`.
- The implementation PR must not add `docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md`.
- `FastCheck.Sales.TicketPage.resolve/1` must preserve its legacy map shape.
- `Artifact.scanner_payload` must map back to legacy `qr_payload`.
- `SecureTicketController` and `secure_ticket_html/show.html.heex` must not change.
- Scanner-display authority remains Attendee/mobile scanner eligibility, not `TicketIssue.scanner_status`.
- Scanner payload must come from `FastCheck.Tickets.QrPayload.build_for_scanner/1`.
- TOON prompts are included.
- Custom `Inspect` redaction for `FastCheck.Tickets.Artifact` and `FastCheck.Tickets.ArtifactError` is required because `scanner_payload` is currently the plain ticket code.

## Important

This pack is planning and implementation guidance only. It contains no implementation code.

The agent must implement only VS-24A and must not build PDF, Apple Wallet, or Google Wallet functionality yet.
