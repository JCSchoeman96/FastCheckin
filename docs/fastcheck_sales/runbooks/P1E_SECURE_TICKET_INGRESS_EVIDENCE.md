# P1-E Secure Ticket Ingress Evidence

## Status

```text
P1E_F_HARD_CUTOVER=PASS
P1E_G_CAPACITY_CONCURRENCY=PASS
P1E_H_PRODUCTION_CANARY=PASS

RAILWAY_RAW_PATH_LOGGING=CONFIRMED
SUPPORTED_SECURE_TICKET_REQUEST_TARGETS_SAFE=PASS
INGRESS_REQUEST_LOGGING_SAFE=PASS

P1E_INGRESS_BLOCKER=CLEARED
```

Repository authority at gate closure documentation:

```text
MAIN_SHA=49d4a0b2014d6b1e4968618f7bd18cb809697ffa
MAIN_TREE=d4d1d29953b71eddda503e4cf842920054c75dd6
```

## Security invariant

```text
NO PLAINTEXT DELIVERY BEARER IN HTTP REQUEST TARGET
```

For the supported customer flow:

- Outbound links use `/t#<delivery-token>` (fragment only).
- The browser sends the transient delivery token only in `POST /t/session` body.
- Authorized reads use `/t/view/:ticket_issue_id` (and optional PDF) with session authorization, not path bearers.
- Legacy `/t/:token` and `/t/:token/pdf` are hard rejection sinks (terminal 404).

Railway/request-edge raw path logging was **not** disabled. P1-E removed valid delivery bearers from supported HTTP request targets.

## Production authority

P1E-H canary production deployment (P1E-G was test-only; no production app diff):

```text
PROD_CANARY_GIT_SHA=7dcc70fb31031487875e4279340540b6adafc71a
PROD_DEPLOYMENT_ID=438f5e5e-5dfa-46e1-9cec-3e7d3a6770e9
PROD_ACTIVE_STATUS=SUCCESS
HOST=https://scan.voelgoed.co.za
```

## Hard-cutover state

P1E-F merged legacy bearer paths to terminal rejection. WhatsApp outbound links use fragment URLs (P1E-E). Supported authorization no longer depends on `GET /t/:token`.

## P1E-H production canary

```text
CANARY_DATE=2026-10-09
T0=2026-10-09T05:47:33Z
T1=2026-10-09T05:47:34Z
REAL_BEARER_USED=NO
DURABLE_BUSINESS_WRITE=NO
```

Three synthetic, non-secret markers (`p1eh-fragment-<synthetic-nonce>`, `p1eh-session-body-<synthetic-nonce>`, `p1eh-legacy-control-<synthetic-nonce>`). Random nonce values are not recorded here.

### Evidence retrieval

`T0` and `T1` record when the three synthetic production requests were issued.

A strict Railway query scoped to `T0`–`T1` with `--until` returned no lines, consistent with log-ingestion latency for the sub-second request sequence. No safety conclusion was drawn from that empty result.

After log ingestion:

- The three expected HTTP requests were verified by their exact Railway request IDs (recorded below).
- Marker absence was checked against a bounded approximately 10-minute Railway HTTP log capture containing **4** lines: fragment marker **0**, session-body marker **0**, legacy positive-control marker **1**.
- Application/service marker absence was checked against a bounded approximately 10-minute Railway service-log capture containing **6** lines: fragment and session-body marker matches **0** each.

Request IDs establish the expected `GET /t`, `POST /t/session`, and legacy `404` requests. The bounded HTTP capture establishes marker match counts.

### Bootstrap (fragment negative control)

- Client-visible URL: `/t#<fragment-marker>`
- HTTP request target: `/t`
- Response: `200`, `Referrer-Policy: no-referrer`, no `Location`
- Railway request id: `0LBE20FsT7C3BUOys_GTAg`

### Session body canary

- `POST /t/session` with synthetic `delivery_token` in form body only
- Response: `422`, no ticket-session cookie, no `Location`, marker not reflected in body
- Railway request id: `1hKPztNnSu-_X2YlWVMv1w`

### Legacy positive control

- `GET /t/p1eh-legacy-control-<synthetic-nonce>`
- Response: `404`, no redirect, `Referrer-Policy: no-referrer`, marker not reflected in body
- Railway request id: `QLZGcpAEQEm1ZEMHN8N_Fg`

## Railway positive-control evidence

Railway HTTP evidence collected after log ingestion (exact request-id lookup) showed the legacy positive-control request:

```json
{"method":"GET","path":"/t/p1eh-legacy-control-<synthetic-nonce>","httpStatus":404,"requestId":"QLZGcpAEQEm1ZEMHN8N_Fg","deploymentId":"438f5e5e-5dfa-46e1-9cec-3e7d3a6770e9"}
```

This proves raw request-path logging and search work. Arbitrary legacy-path strings may appear in logs; that does **not** mean the supported flow leaks delivery bearers.

## Supported-flow negative-control evidence

Railway HTTP evidence collected after log ingestion:

- Bootstrap and exchange: verified by request IDs above (`GET /t` `200`, `POST /t/session` `422`).
- Marker match counts: bounded approximately 10-minute HTTP capture (**4** lines total).
- Fragment marker: **0** matches in request `path` fields
- Session body marker: **0** matches in request `path` fields

## Application/service-log evidence

A bounded approximately 10-minute Railway service-log capture containing the canary period (**6** lines total) showed:

```text
APP_LOG_FRAGMENT_MARKER_MATCHES=0
APP_LOG_SESSION_MARKER_MATCHES=0
```

## Gate interpretation

```text
RAILWAY_RAW_PATH_LOGGING=CONFIRMED
SUPPORTED_FLOW_BEARER_IN_REQUEST_TARGET=NO
INGRESS_REQUEST_LOGGING_SAFE=PASS
```

Do not claim Railway stopped logging paths or that `/t/:token`-shaped paths can never appear in logs. The launch gate is satisfied because the **supported** ticket flow does not place a valid delivery bearer in HTTP request targets.

## Closure

P1E-I records master-reviewed P1E-H evidence and updates current launch runbooks. Implementation phases P1E-A through P1E-H are complete per frozen plan v1.5 (`P1E-I = gate closure`).

## Remaining launch checks

Clearing P1E does not clear unrelated environment, provider, runtime, or operational launch checklist items. Operators must still complete go/no-go, monitoring, and incident procedures for the target environment.
