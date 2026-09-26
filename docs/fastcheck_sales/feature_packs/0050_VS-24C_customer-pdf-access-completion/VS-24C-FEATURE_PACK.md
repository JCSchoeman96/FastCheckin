# VS-24C customer PDF access completion

## Scope

VS-24C completes customer self-service PDF access for issue #440. A customer who holds a valid secure-ticket delivery token can download a fresh PDF from the existing ticket page.

The browser route is `GET /t/:token/pdf`. On every request, `SecureTicketPdfController` calls `ArtifactResolver.resolve_from_delivery_token/1`. It calls `PdfTicket.generate/1` only after the resolver returns a valid artifact. The endpoint never trusts the state from an earlier page request.

The secure ticket page shows a `Download PDF` link only when `TicketPage.resolve/1` returns `:valid`. The token appears in the same-origin route URL, which already uses that token as its bearer authority.

## Existing work

- VS-24A defined the artifact contract and resolver.
- VS-24B added the renderer-only PDF generator.
- #446 and PR #448 added admin/manual PDF download.
- #447 added verified WhatsApp resend. WhatsApp continues to send the secure ticket-page link.
- This slice completes #440 by adding customer self-service PDF access.

WhatsApp does not attach PDF binaries. The endpoint does not store PDFs or create a PDF lifecycle record.

## Validity and lifecycle

PDF availability follows current ticket and delivery-token authority:

- A valid token and ticket produce a request-local PDF.
- An invalid or unknown token returns 404.
- An expired token or revoked ticket returns 410.
- An archived event, ticket that is not ready, or attendee that cannot be scanned returns 409.
- A renderer failure returns 500.

Each failure uses the generic message `Ticket PDF is not available for download.` No ticket, attendee, order, payment, or delivery state changes during resolution or rendering.

## Privacy and caching

Secure ticket page and PDF responses use:

- `Cache-Control: no-store, private`
- `Pragma: no-cache`
- `X-Robots-Tag: noindex, nofollow`
- `Referrer-Policy: no-referrer`

The route uses the existing browser `RateLimiter`. It adds no cache, PDF persistence, migration, Redis, ETS, CDN, or background job. A PDF is regenerated from freshly resolved state for each request.

The generated PDF may contain the scanner ticket code. Response headers and error bodies do not contain the delivery token, hashes, payment data, buyer contact details, or provider payloads.

## Verification

The focused tests cover valid downloads, failure states, response redaction, page integration, state revalidation after revocation, and no mutation. The slice also requires the existing artifact, renderer, TicketPage, admin PDF, WhatsApp, checkout-to-scanner, and revocation/scanner-visibility tests, followed by `mix precommit`, `mix sobelow --exit --compact`, and `git diff --check`.
