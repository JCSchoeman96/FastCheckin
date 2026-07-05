# VS-24E TOON Prompts

## Scaffolding Prompt

| Field | Content |
|---|---|
| Task | Create the VS-24E docs-only validation slice scaffold. |
| Objective | Establish a complete smoke-test feature pack that proves the current checkout, payment, ticket issuance, delivery, PDF manual download, scanner, and resend loop before wallet work begins. |
| Output | `docs/fastcheck_sales/feature_packs/0049_VS-24E_production-checkout-ticket-delivery-smoke-test/VS-24E-FEATURE_PACK.md`, `CODING_AGENT_PROMPT.md`, `TOON_PROMPTS.md`, `ACCEPTANCE_CHECKLIST.md`, `EVIDENCE_TEMPLATE.md`, `pack.json`, plus runbooks under `docs/fastcheck_sales/runbooks/`. |
| Note | Docs-only. Do not edit app code, config, migrations, router, controllers, workers, payment modules, ticket modules, scanner modules, wallet modules, Android code, assets, or tests unless explicitly instructed. If `0049` conflicts, use the next available ordinal. No secrets, PII, tokens, payment URLs, or protected screenshots in docs. Existing data layers only: Redis for inventory/session/dedupe, Postgres durable records, Oban workers. No new Redis keys, indexes, PubSub, cache, or runtime behavior. |

## Grouped Micro-Prompts

### 1. Repo Truth And Scope

| Field | Content |
|---|---|
| Task | Inspect current `main` and document the VS-24E repo-truth baseline. |
| Objective | Ensure the runbook is based on current code behavior, not assumptions about future wallet or PDF delivery features. |
| Output | Add a Current Repo Truth section to `VS-24E-FEATURE_PACK.md`. |
| Note | State that customer delivery is secure ticket link today; PDF is dashboard-only/manual staff download. Mention payment verification, ticket issuance, secure ticket, scanner, resend, and PDF boundaries. No code changes. No protected values. |

### 2. Feature Pack Summary

| Field | Content |
|---|---|
| Task | Write the VS-24E feature pack summary. |
| Objective | Define VS-24E as a production-readiness smoke-test slice before VS-25 wallet work. |
| Output | `VS-24E-FEATURE_PACK.md` with Summary, Goal, Non-goals, Dependencies, Scope, Acceptance Criteria, Verification, and Go/No-Go sections. |
| Note | Non-goals must explicitly forbid Apple Wallet, Google Wallet, PDF attachment resend, customer PDF delivery, payment authority changes, ticket issuance authority changes, scanner changes, webhook changes, refund/revocation changes, and storage of generated PDFs. |

### 3. Runbook Integration

| Field | Content |
|---|---|
| Task | Create the VS-24E smoke-test runbook. |
| Objective | Provide the exact operator path for validating WhatsApp checkout through ticket delivery and post-payment artifacts. |
| Output | `docs/fastcheck_sales/runbooks/VS-24E_PRODUCTION_CHECKOUT_TICKET_DELIVERY_SMOKE_TEST.md`. |
| Note | Build on the existing Sandbox Dress Rehearsal and Go/No-Go checklist. Include staging/test mode first, then optional low-value production smoke. Use redacted placeholders for order references, payment attempt IDs, and delivery attempt IDs. Do not include raw payment links, ticket links, phone numbers, emails, OTPs, tokens, hashes, or provider payloads. |

### 4. Environment Preflight

| Field | Content |
|---|---|
| Task | Add a VS-24E environment preflight section. |
| Objective | Ensure the app, database, Redis, Oban, Paystack, WhatsApp, dashboard, and scanner environment are ready before any manual payment run. |
| Output | Preflight section in `VS-24E_PRODUCTION_CHECKOUT_TICKET_DELIVERY_SMOKE_TEST.md`. |
| Note | Include checks for CI green, deployed commit SHA, migrations applied, Redis reachable, Oban running, Paystack mode confirmed, Meta/WhatsApp enabled deliberately, dashboard auth works, mobile scanner config ready. No command should print secrets. No broad production DB scans. |

### 5. Happy Path Smoke

| Field | Content |
|---|---|
| Task | Write the full happy-path smoke procedure. |
| Objective | Validate the complete customer money-to-ticket loop in the real platform shape. |
| Output | Happy Path section in `VS-24E_PRODUCTION_CHECKOUT_TICKET_DELIVERY_SMOKE_TEST.md`. |
| Note | Steps: WhatsApp start, event selection, offer selection, quantity, buyer details, confirmation, Paystack payment link sent, payment completed, webhook received, server verification success, order paid, ticket issued, ticket link sent, secure ticket page opens, admin PDF download works, scanner sync sees attendee, valid scan succeeds, resend via WhatsApp + email OTP works. Customer PDF attachment must not be expected. |

### 6. PDF Manual Download Check

| Field | Content |
|---|---|
| Task | Add a dashboard PDF manual download validation section. |
| Objective | Validate the existing PDF path without pretending it is customer attachment delivery. |
| Output | PDF section in `VS-24E_PRODUCTION_CHECKOUT_TICKET_DELIVERY_SMOKE_TEST.md`. |
| Note | Use dashboard/admin route only. Confirm generated PDF downloads as `application/pdf`, is private/no-store/noindex where applicable, and contains customer-safe ticket details only. Do not create delivery attempts, send messages, store PDFs, or expose public delivery tokens. |

### 7. Failure Matrix

| Field | Content |
|---|---|
| Task | Create the VS-24E failure matrix. |
| Objective | Define fail-closed expectations for payment, ticketing, delivery, scanner, PDF, and resend failures. |
| Output | `docs/fastcheck_sales/runbooks/VS-24E_FAILURE_MATRIX.md`. |
| Note | Include abandoned payment, duplicate webhook, provider pending, amount mismatch, currency mismatch, reference mismatch, expired checkout, duplicate ticket issuer run, WhatsApp send failure, secure token invalid/expired, revoked ticket, refunded/cancelled order, archived/not-scannable ticket, wrong resend identity, wrong OTP, OTP lock, duplicate resend, dashboard PDF unavailable, and scanner acceptance of invalid ticket. For each: expected customer response, expected DB state, expected worker behavior, expected audit/log safety. |

### 8. Evidence Template

| Field | Content |
|---|---|
| Task | Create a redacted evidence template for the smoke run. |
| Objective | Standardize what the operator records without leaking protected values. |
| Output | `EVIDENCE_TEMPLATE.md`. |
| Note | Evidence may include commit SHA, environment, date/time, event label, redacted order reference suffix, payment attempt ID, payment event ID, ticket issue ID, delivery attempt ID, Oban job IDs, pass/fail notes. Must not include raw payment URL, Paystack access code, ticket link, delivery token, token hash, QR hash, OTP, phone, email, raw provider payload, or screenshots containing those values. |

### 9. Production Low-Value Smoke

| Field | Content |
|---|---|
| Task | Create the optional low-value production smoke checklist. |
| Objective | Provide a safe controlled live-payment validation after staging passes. |
| Output | `docs/fastcheck_sales/runbooks/VS-24E_PRODUCTION_LOW_VALUE_SMOKE.md`. |
| Note | Use hidden/internal event and low-value ticket if approved. Require launch owner/operator signoff before real payment. Include cleanup policy: revoke/refund only if approved. Stop immediately on payment mismatch, duplicate issuance, scanner acceptance of invalid ticket, or secret leakage. |

### 10. Resend Validation

| Field | Content |
|---|---|
| Task | Add resend validation steps to the smoke runbook. |
| Objective | Confirm verified resend remains correct in the real platform flow. |
| Output | Resend section in `VS-24E_PRODUCTION_CHECKOUT_TICKET_DELIVERY_SMOKE_TEST.md`. |
| Note | Validate WhatsApp option, name/email collection, email OTP, verified resend queued, secure ticket link sent, challenge consumed, DeliveryAttempt has `delivery_reason = verified_ticket_resend` and internal challenge ID only. Wrong identity and wrong OTP must fail generically. No OTP/public challenge ID/email/phone/token/hash in logs or responses. |

### 11. Scanner Validation

| Field | Content |
|---|---|
| Task | Add scanner/mobile validation steps. |
| Objective | Prove issued tickets are visible to scanner and invalidated tickets fail closed. |
| Output | Scanner section in `VS-24E_PRODUCTION_CHECKOUT_TICKET_DELIVERY_SMOKE_TEST.md`. |
| Note | Validate mobile sync sees the issued attendee, scan succeeds once according to current scanner rules, revoked/refunded/not-scannable ticket is rejected. Do not change scanner code or scanner authority. Use existing mobile/scanner endpoints and approved operator device/session. |

### 12. Ops Dashboard And Audit Timeline

| Field | Content |
|---|---|
| Task | Add ops dashboard and audit timeline checks. |
| Objective | Ensure operators can observe the transaction without seeing protected internals. |
| Output | Ops/Audit section in the VS-24E runbook. |
| Note | Check `/dashboard/sales/ops`, order page, delivery attempts, payment attempts/events, ticket issue, conversation, resend challenge, and audit timeline. Evidence must use IDs/statuses only. No raw PII, tokens, payment URLs, provider payloads, or QR hashes. |

### 13. Redaction And Log Spot Check

| Field | Content |
|---|---|
| Task | Add a redaction/log inspection checklist. |
| Objective | Catch leaks before wallet work builds on this delivery chain. |
| Output | Redaction section in the runbook and acceptance checklist. |
| Note | Confirm logs/Sentry/evidence do not contain phone numbers, emails, OTPs, payment links, access codes, ticket links, delivery tokens, delivery token hashes, QR hashes, ticket codes, raw provider payloads, or raw internal structs. Treat leakage as a stop-ship incident. |

### 14. Verification Commands

| Field | Content |
|---|---|
| Task | Add the required automated verification commands. |
| Objective | Anchor the manual smoke to green automated coverage before execution. |
| Output | Verification sections in `VS-24E-FEATURE_PACK.md` and `CODING_AGENT_PROMPT.md`. |
| Note | Include `mix format --check-formatted`, `mix compile --warnings-as-errors`, relevant VS-22 E2E suites, payment/Paystack tests, WhatsApp payment/ticket/resend tests, PDF controller tests, secure ticket tests, scanner/revocation visibility tests, `mix sobelow --exit --compact`, and `mix precommit`. The agent may adjust exact test file paths only after inspecting repo truth. |

### 15. No-Code Boundary Check

| Field | Content |
|---|---|
| Task | Add a final no-code diff check. |
| Objective | Prevent the validation slice from accidentally changing production behavior. |
| Output | Final Review section in `CODING_AGENT_PROMPT.md`. |
| Note | The final diff should include docs/runbook/feature-pack files only. If any `lib/`, `config/`, `priv/repo/migrations/`, `assets/`, router, controller, worker, payment, ticket, scanner, wallet, Android, or test file changes are present, stop and ask for review before proceeding. |
