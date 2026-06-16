Plan ID: VS-03-ticket-offer-management
Plan version: v1
Status: Approved after reviewer feedback
Scope: VS-03 Ticket Offer Management
Authority: This file is the active implementation contract for VS-03. The VS-03 feature pack is the upstream source. VS-01B, VS-01F, VS-01G, and VS-02 handoffs define merged implementation reality.
Last updated: 2026-06-16

## Revision log
- v1 — initial VS-03 implementation plan based on VS-03 feature pack and merged Sales handoffs.

## Implementation boundary
- Implement only VS-03 TicketOffer actions, validations, policies, active offer filtering, durable checkout-eligibility read, nullable-window migration, centralized cache invalidation boundary, focused tests, and slice docs.
- Do not implement Redis inventory, ReservationLedger, checkout/orders workflows, Paystack, WhatsApp/Meta, ticket issuance, attendee/scanner/mobile/Android/UI changes, or dependency upgrades.
