# Sales Core Bridge MVP

## Purpose

Define how pre-launch build paths validate the shared Sales core without
becoming separate workflows.

## Included Before First Launch

- `internal_pilot_sales`
- `admin_assisted_sales`

## Deferred

- `web_checkout_sales`

## Required Shared Core Behavior

Every included bridge path must:

- create durable Order/CheckoutSession/PaymentAttempt records through approved
  services;
- call `ReservationLedger` for inventory;
- initialize Paystack transactions through the approved Paystack boundary;
- require server-side verification before verified payment;
- issue tickets only through the approved issuer;
- record `DeliveryAttempt` and `StateTransition` audit;
- preserve source channel attribution;
- respect event-scoped access and log-redaction policy.

## VS-05A Scope

VS-05A is `Secondary Sales Entry Points`. It may include internal pilot
order/checkout creation and admin-assisted checkout link creation.

VS-05A must not claim to implement WhatsApp-first checkout by itself. WhatsApp
first checkout belongs to VS-17, VS-18, VS-19, and VS-20.
