# VS-24A Implementation Handoff Template — POST-MERGE ONLY

Do not add this file in the VS-24A implementation PR.

Use this template only after VS-24A is merged, in a separate docs-only handoff PR:

```text
docs/fastcheck_sales/handoffs/VS-24A_IMPLEMENTATION_HANDOFF.md
```

## Summary

- Added shared ticket artifact contract.
- Added read-only artifact resolver.
- Refactored `FastCheck.Sales.TicketPage.resolve/1` to consume artifact resolver while preserving legacy secure-page result shape.
- Did not change payment, issuance, scanner, revocation, delivery, WhatsApp, PDF, Apple Wallet, or Google Wallet behavior.

## Completed Files

- `lib/fastcheck/tickets/artifact.ex`
- `lib/fastcheck/tickets/artifact_error.ex`
- `lib/fastcheck/tickets/artifact_resolver.ex`
- `lib/fastcheck/sales/ticket_page.ex`
- `test/fastcheck/tickets/artifact_resolver_test.exs`
- `test/fastcheck/sales/ticket_page_test.exs`
- `test/fastcheck_web/controllers/secure_ticket_controller_test.exs` if changed

## Future Slices Can Rely On

- `FastCheck.Tickets.ArtifactResolver.resolve_from_delivery_token/1`
- `FastCheck.Tickets.Artifact` safe scalar fields
- `scanner_payload` built through `QrPayload.build_for_scanner/1`
- Inspect redaction for `Artifact` and `ArtifactError` so scanner payloads do not appear in logs/test failures
- Secure ticket page remains a consumer through `TicketPage.resolve/1`

## Deferred

- PDF renderer
- Apple Wallet renderer
- Google Wallet renderer
- artifact persistence
- artifact caching
- wallet signing/certificates
- download/resend flows

## Verification Summary

Paste final command results here after merge:

```bash
mix format
mix test test/fastcheck/tickets/artifact_resolver_test.exs
mix test test/fastcheck/sales/ticket_page_test.exs
mix test test/fastcheck_web/controllers/secure_ticket_controller_test.exs
mix test test/fastcheck/sales/e2e/checkout_to_scanner_test.exs
mix test test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs
mix precommit
```
