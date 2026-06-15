# VS-00B Security, PII, and Token Policy Finalization

## Purpose

Define security, PII, raw provider payload, token, log-redaction, and
field-access policy before resource implementation, provider integration, admin
UI, customer ticket pages, or WhatsApp flows are built.

## Scope

In scope:

- PII and sensitive provider data classification.
- Actor access rules for `system`, `admin`, `operator`, and
  `customer_session`.
- Event-scoped-first access policy.
- Admin/operator display masking.
- Customer-facing token hashing, expiry, revocation, and log-redaction rules.
- Raw provider payload access and retention.
- Paystack and Meta/WhatsApp security expectations.

Out of scope:

- Elixir implementation.
- Ash policies.
- Migrations.
- Token generation code.
- Provider clients.
- Oban workers.
- LiveView/admin UI.
- Customer ticket page.
- Tests.
- Android scanner or mobile API changes.

## Documents

- [Security Master](../security/SECURITY_PII_TOKEN_MASTER.md)
- [PII Data Classification](../security/PII_DATA_CLASSIFICATION.md)
- [Ash Field Access Policy](../security/ASH_FIELD_ACCESS_POLICY.md)
- [Admin Operator Display Policy](../security/ADMIN_OPERATOR_DISPLAY_POLICY.md)
- [Customer Token Policy](../security/CUSTOMER_TOKEN_POLICY.md)
- [Log Redaction Policy](../security/LOG_REDACTION_POLICY.md)
- [Raw Provider Payload Policy](../security/RAW_PROVIDER_PAYLOAD_POLICY.md)
- [Secret and Config Policy](../security/SECRET_AND_CONFIG_POLICY.md)
- [Tenant Event Access Policy](../security/TENANT_EVENT_ACCESS_POLICY.md)
- [Paystack Security Policy](../security/PAYSTACK_SECURITY_POLICY.md)
- [Meta WhatsApp Security Policy](../security/META_WHATSAPP_SECURITY_POLICY.md)
- [Security Test Plan](../security/SECURITY_TEST_PLAN.md)

## Completion Checklist

- [x] Classify PII and sensitive provider/token fields.
- [x] Define actor access for `system`, `admin`, `operator`, and
  `customer_session`.
- [x] Define event-scoped-first access policy.
- [x] Require masked admin/operator list views.
- [x] Require restricted raw provider payload access.
- [x] Require hashed customer-facing tokens only.
- [x] Require token expiry/revocation and token-bearing URL log redaction.
- [x] Require Paystack server-side verification.
- [x] Treat Meta/WhatsApp identifiers and message content as sensitive.

## RED Documentation Checks

VS-00B is not accepted if:

- PII classification is missing.
- Actor access rules are missing.
- Admin/operator masking rules are missing.
- Plaintext customer-facing token storage is allowed.
- Token-bearing URLs, `authorization_url`, or `access_code` may be logged.
- Operators can view raw provider payloads by default.
- `customer_session` can perform broad reads.
- Raw provider payload retention is undefined.
- Paystack webhook payload alone can be payment authority.
- WhatsApp is allowed to own payment, inventory, ticket issuance, or scanner
  validity.
- Event-scoped access is not required.

## GREEN Documentation Checks

VS-00B is accepted when:

- All required security documents exist.
- Sensitive fields are classified.
- Every actor type has field-access expectations.
- Admin and operator display rules are separate.
- Customer-session access is token/session/order scoped.
- Raw provider payload access is restricted and retention is defined.
- Customer token policy requires hashing, expiry/revocation, and redaction.
- Paystack policy requires signature checks and server-side verification.
- Meta/WhatsApp policy treats identifiers and message content as PII.
- No implementation code is added.

## Acceptance Criteria

- Security docs exist in allowed docs paths.
- `event_scoped_first` is locked for first release.
- `organization_id` is deferred.
- Future implementation test expectations are documented.
- No runtime behavior is changed.
