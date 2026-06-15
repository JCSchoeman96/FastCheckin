# Selected Launch Scope

## Selected Scope

```text
primary_launch_scope: whatsapp_first_paid_core

secondary_paths_before_first_launch:
  - internal_pilot_sales
  - admin_assisted_sales

secondary_paths_after_first_launch:
  - web_checkout_sales
```

## Public Web Checkout Decision

`web_checkout_sales` is deferred. Public web checkout must not be included before
the first WhatsApp-first production launch.

It may be planned as a later secondary channel only after:

- shared Sales core is stable;
- Paystack verification is stable;
- ticket issuance is idempotent and stable;
- `DeliveryAttempt` audit is stable;
- scanner-safe revocation is stable;
- WhatsApp-first production path is stable.

## Admin-Assisted Sales Decision

Admin-assisted sales may be included before launch only as a controlled secondary
path over the same Sales core. It must not bypass:

- Redis inventory;
- Paystack verification;
- idempotent ticket issuance;
- `DeliveryAttempt` audit;
- `StateTransition` audit;
- scanner-safe revocation.
