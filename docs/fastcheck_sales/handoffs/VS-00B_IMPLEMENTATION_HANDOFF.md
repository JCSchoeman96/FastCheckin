# VS-00B Implementation Handoff

## Status

Merged.

PR: #329 — Docs: FastCheck Sales VS-00 planning gates  
Merge commit: `1257501cd8f31e8b577e98f5508addca3818cc2d`  
Implementation commit: `33b15b362bc7ebb9c098bbe302394e13df05031c`  
Merged at: 2026-06-15T07:21:41Z  
Branch: `docs/fastcheck-sales-vs00-planning-gates`

VS-00B was merged as part of grouped PR #329. The VS-00B implementation commit
is represented in the squash/merge commit #329 produced on main.

## What Changed

VS-00B added the documentation-only security contract for FastCheck Sales before
Sales resources, provider integrations, admin UI, customer ticket pages, or
WhatsApp flows were implemented.

The slice defined Sales security, PII classification, token handling, raw
provider payload handling, log redaction, secret/config handling, tenant/event
access, Paystack security, and Meta/WhatsApp security policy. It also documented
future security acceptance checks for implementation slices.

No runtime code, migrations, Ash resources, workers, routes, controllers,
LiveViews, scanner changes, Android changes, Paystack client, Meta client, Redis
behavior, token generation, or customer ticket page behavior was added.

## Files Changed

- `docs/fastcheck_sales/slices/VS-00B_SECURITY_PII_AND_TOKEN_POLICY_FINALIZATION.md`
  — slice summary, scope, acceptance criteria, and RED/GREEN documentation
  checks.
- `docs/fastcheck_sales/security/SECURITY_PII_TOKEN_MASTER.md` — master security
  principles, actor model, and event-scoped-first posture.
- `docs/fastcheck_sales/security/PII_DATA_CLASSIFICATION.md` — PII and
  sensitive-provider-data classes for Sales fields.
- `docs/fastcheck_sales/security/ASH_FIELD_ACCESS_POLICY.md` — expected Ash
  field-level access posture by actor.
- `docs/fastcheck_sales/security/ADMIN_OPERATOR_DISPLAY_POLICY.md` —
  admin/operator display and masking expectations.
- `docs/fastcheck_sales/security/CUSTOMER_TOKEN_POLICY.md` — customer-facing
  delivery/QR token hashing, expiry, revocation, and redaction rules.
- `docs/fastcheck_sales/security/LOG_REDACTION_POLICY.md` — logging and URL
  redaction requirements for PII, tokens, provider payloads, and secrets.
- `docs/fastcheck_sales/security/RAW_PROVIDER_PAYLOAD_POLICY.md` — raw Paystack
  and Meta provider payload retention/access posture.
- `docs/fastcheck_sales/security/SECRET_AND_CONFIG_POLICY.md` — secret and
  runtime configuration handling expectations.
- `docs/fastcheck_sales/security/TENANT_EVENT_ACCESS_POLICY.md` — first-release
  event-scoped access policy and deferred organization tenancy.
- `docs/fastcheck_sales/security/PAYSTACK_SECURITY_POLICY.md` — Paystack
  webhook, initialization, verification, and payment-authority rules.
- `docs/fastcheck_sales/security/META_WHATSAPP_SECURITY_POLICY.md` —
  Meta/WhatsApp identifier, message, and channel-boundary security rules.
- `docs/fastcheck_sales/security/SECURITY_TEST_PLAN.md` — future security test
  expectations for implementation slices.

## Contracts Now Available

- PII classification exists for buyer, attendee, delivery-recipient,
  provider-identifier, WhatsApp, token, and raw provider payload data.
- Supported Sales actor types are `system`, `admin`, `operator`, and
  `customer_session`.
- First release uses `event_scoped_first`; event scope is required and role
  alone is insufficient.
- `organization_id` is deferred until a later approved tenant-isolation slice.
- Customer-facing delivery and QR tokens are hash-only at rest.
- Customer-facing tokens require expiry and revocation handling.
- Token-bearing URLs must not be logged.
- Raw provider payloads are restricted and must not be exposed to operators or
  customer sessions by default.
- Paystack webhook payload alone is not payment authority.
- Paystack verification must be server-side.
- WhatsApp/Meta is an interface layer, not the authority for inventory, payment,
  ticket issuance, or scanner validity.
- Admin/operator display rules are distinct; operator-facing surfaces are masked
  and narrower than admin support views.
- Security test expectations are documented for later implementation slices.

## Decisions Applied

- Keep Sales security policy channel-agnostic: WhatsApp, admin-assisted,
  internal pilot, and future web checkout paths must share the same core
  security contracts.
- Treat Meta/WhatsApp identifiers and message content as sensitive provider/PII
  data.
- Treat Paystack provider references, authorization URLs, access codes, and raw
  responses as restricted provider data.
- Fail closed for broad customer-session access; customer access must be scoped
  to controlled token/session/order flows.
- Keep provider HTTP calls, token generation, Redis inventory mutation, and
  scanner validity outside Ash resources.
- Keep existing Attendee/scanner validity in the existing Ecto/scanner path.
- Document RED/GREEN security criteria before later slices implement policies in
  runtime code.

## Boundaries Still Enforced

- No implementation code in VS-00B.
- No Ash policy implementation.
- No Ash resources or resource actions.
- No migrations or schema changes.
- No token generation code.
- No QR rendering.
- No customer ticket page.
- No scanner or mobile API changes.
- No Paystack client, webhook controller, initialization, or verification code.
- No Meta/WhatsApp client or webhook implementation.
- No Redis inventory, Lua scripts, or cache behavior.
- No Oban workers.
- No LiveView/admin/customer UI.

## Tests Added Or Updated

VS-00B did not add executable tests. It added documentation-level RED/GREEN
security checks and future acceptance criteria in:

- `docs/fastcheck_sales/slices/VS-00B_SECURITY_PII_AND_TOKEN_POLICY_FINALIZATION.md`
- `docs/fastcheck_sales/security/SECURITY_TEST_PLAN.md`

Later slices, including VS-01F, VS-08, VS-11, VS-16, VS-17, VS-20, and VS-21A,
must translate the relevant VS-00B contracts into executable tests when they
implement runtime behavior.

## Verification Reported

PR #329 was a docs-only planning-gate PR. The VS-00B slice checklist in the PR
covered PII classification, actor access, event-scoped-first access, token
hashing, token expiry/revocation, token-bearing URL redaction, Paystack
server-side verification, and WhatsApp/Meta sensitivity rules.

The implementation evidence on main shows:

- PR #329 merged successfully.
- Commit `33b15b362bc7ebb9c098bbe302394e13df05031c` added the VS-00B policy
  documents.
- Merge commit `1257501cd8f31e8b577e98f5508addca3818cc2d` contains the grouped
  VS-00 planning-gate docs.

No runtime test results are associated with VS-00B because the slice was
documentation-only.

## Known Limitations

- VS-00B defines contracts only.
- Later slices implement these policies in code, tests, resources, controllers,
  workers, provider boundaries, and UI surfaces.
- VS-00B has no post-merge runtime verification beyond docs presence/content
  checks.
- VS-11 still requires its own route, token-hash lookup, invalid-state,
  response-header, no-raw-token-logging, and rate-limit tests.
- VS-00B does not itself provide customer ticket-page access or delivery.

## Next Agent Guidance

Reuse the VS-00B security docs as the source of truth for Sales security,
privacy, token, raw-payload, and access-control behavior. Do not weaken token
storage, log redaction, raw provider payload, or event-scoping rules in later
slices.

For VS-11 specifically:

- Hash the raw delivery token before lookup.
- Do not log raw route tokens, token hashes, or full token-bearing URLs.
- Do not expose usable ticket codes or QR payloads for invalid, expired,
  revoked, not-ready, or not-scannable states.
- Do not publicly cache ticket pages.
- Do not create `DeliveryAttempt` rows.
- Do not add WhatsApp/email delivery.
- Do not change scanner, mobile sync, Android, Paystack, order, checkout, or
  inventory behavior.

Keep the existing VS-00B policy docs unchanged unless a later explicit security
policy revision slice owns the change.

## Next Slice

Recommended unblock path: re-run VS-11 planning after this handoff is merged.

Entry condition for VS-11:

- This VS-00B handoff is present in
  `docs/fastcheck_sales/handoffs/VS-00B_IMPLEMENTATION_HANDOFF.md`.
- `docs/fastcheck_sales/handoffs/README.md` lists VS-00B.
- VS-08, VS-09D, VS-10, VS-21A, and other direct predecessor handoffs remain
  available.
- VS-11 planning reads this handoff and preserves VS-00B token, PII, no-raw-log,
  and customer-session boundaries.
