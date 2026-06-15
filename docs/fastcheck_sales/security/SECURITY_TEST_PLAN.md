# Security Test Plan

## Future Implementation Test Categories

- Ash policy tests for field-level restrictions.
- Event-scoped allow/deny tests for admin/operator reads.
- Cross-event denial tests for admin/operator manual actions.
- Customer-session broad-read denial tests.
- Admin/operator list masking tests.
- Raw provider payload access tests.
- Operator raw-payload denial tests.
- Customer token invalid/expired/revoked access tests.
- No plaintext token persistence tests.
- No token-bearing URL logging tests.
- Paystack initialization log-redaction tests.
- Paystack webhook ingestion log-redaction tests.
- Meta webhook ingestion log-redaction tests.

## Example RED Tests

- Operator can read `PaymentEvent.raw_payload` by default.
- Customer session can list `Sales.Order` broadly.
- Logs include Paystack `authorization_url`.
- Delivery token is stored plaintext.
- Revoked token still renders a QR.
- Operator from one event can list another event's orders.

## Example GREEN Tests

- Admin can access restricted raw payload detail through approved event-scoped
  view.
- Operator sees masked `buyer_phone` in dashboard list.
- Customer session can access only a valid token-scoped ticket page.
- Expired token does not reveal whether ticket exists.
- Paystack `access_code` never appears in captured logs.
- Cross-event admin/operator reads are denied.
