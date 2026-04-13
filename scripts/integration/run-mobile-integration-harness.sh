#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android/scanner-app"

ATTENDEES="${ATTENDEES:-40}"
CREDENTIAL="${CREDENTIAL:-scanner-secret}"
TICKET_PREFIX="${TICKET_PREFIX:-INTEG}"
MANIFEST_PATH="${MANIFEST_PATH:-$ROOT_DIR/.tmp/mobile-integration-manifest.json}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/.tmp/mobile-integration-artifacts}"
PHOENIX_LOG="$ARTIFACT_DIR/phoenix.log"
REVOKE_REASON="${REVOKE_REASON:-revoked}"
KEEP_SEEDED_DATA="${KEEP_SEEDED_DATA:-false}"

TEST_CLASS="za.co.voelgoed.fastcheck.app.MobileIntegrationHarnessFlowTest"
PHASE_1_METHOD="activeTicketIsAcceptedAfterLoginAndSync"
PHASE_2_METHOD="mutatedTicketIsRejectedAfterResync"

mkdir -p "$(dirname "$MANIFEST_PATH")" "$ARTIFACT_DIR"

PHOENIX_PID=""

cleanup() {
  if [[ -n "$PHOENIX_PID" ]] && kill -0 "$PHOENIX_PID" >/dev/null 2>&1; then
    kill "$PHOENIX_PID" >/dev/null 2>&1 || true
    wait "$PHOENIX_PID" >/dev/null 2>&1 || true
  fi

  if [[ "$KEEP_SEEDED_DATA" != "true" ]] && [[ -f "$MANIFEST_PATH" ]]; then
    (
      cd "$ROOT_DIR"
      MIX_ENV=dev mix fastcheck.load.cleanup_mobile_event --manifest "$MANIFEST_PATH" >/dev/null 2>&1 || true
    )
  fi
}
trap cleanup EXIT

run_connected_method() {
  local method_name="$1"
  (
    cd "$ANDROID_DIR"
    ./scripts/run-connected-android-tests.sh \
      --class "${TEST_CLASS}#${method_name}" \
      -- \
      -PFASTCHECK_SCANNER_SOURCE=datawedge \
      -Pandroid.testInstrumentationRunnerArguments.fastcheck.integration=true \
      -Pandroid.testInstrumentationRunnerArguments.fastcheck.eventId="$EVENT_ID" \
      -Pandroid.testInstrumentationRunnerArguments.fastcheck.credential="$CREDENTIAL" \
      -Pandroid.testInstrumentationRunnerArguments.fastcheck.ticketCode="$TICKET_CODE"
  )
}

echo "[harness] Booting local infra..."
(
  cd "$ROOT_DIR"
  docker compose up -d postgres redis pgbouncer
)

echo "[harness] Running DB migrate/reset steps..."
(
  cd "$ROOT_DIR"
  MIX_ENV=dev mix ecto.create
  MIX_ENV=dev mix ecto.migrate
)

echo "[harness] Seeding deterministic scenario..."
(
  cd "$ROOT_DIR"
  MIX_ENV=dev mix fastcheck.load.seed_mobile_event \
    --attendees "$ATTENDEES" \
    --credential "$CREDENTIAL" \
    --ticket_prefix "$TICKET_PREFIX" \
    --output "$MANIFEST_PATH"
)

EVENT_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["event_id"])' "$MANIFEST_PATH")"
TICKET_CODE="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["slices"]["baseline_valid"]["start_ticket"])' "$MANIFEST_PATH")"

echo "[harness] Starting Phoenix server..."
(
  cd "$ROOT_DIR"
  MIX_ENV=dev mix phx.server >"$PHOENIX_LOG" 2>&1
) &
PHOENIX_PID="$!"

echo "[harness] Waiting for backend readiness..."
for _ in $(seq 1 60); do
  if curl --silent --fail "http://127.0.0.1:4000/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl --silent --fail "http://127.0.0.1:4000/" >/dev/null 2>&1; then
  echo "[harness] Backend did not become ready. See $PHOENIX_LOG" >&2
  exit 1
fi

echo "[harness] Running connected test phase 1 ($PHASE_1_METHOD)..."
run_connected_method "$PHASE_1_METHOD"

echo "[harness] Applying backend mutation in outer runner..."
(
  cd "$ROOT_DIR"
  MIX_ENV=dev mix fastcheck.load.revoke_mobile_ticket \
    --event_id "$EVENT_ID" \
    --ticket_code "$TICKET_CODE" \
    --reason_code "$REVOKE_REASON"
)

echo "[harness] Capturing scenario dump after mutation..."
(
  cd "$ROOT_DIR"
  MIX_ENV=dev mix fastcheck.load.dump_mobile_ticket_state \
    --event_id "$EVENT_ID" \
    --ticket_code "$TICKET_CODE" \
    >"$ARTIFACT_DIR/post-mutation-ticket-state.json"
)

echo "[harness] Running connected test phase 2 ($PHASE_2_METHOD)..."
run_connected_method "$PHASE_2_METHOD"

if [[ -d "$ANDROID_DIR/app/build/reports/androidTests/connected" ]]; then
  cp -R "$ANDROID_DIR/app/build/reports/androidTests/connected" "$ARTIFACT_DIR/connected-reports"
fi

echo "[harness] Completed successfully."
echo "[harness] event_id=$EVENT_ID"
echo "[harness] ticket_code=$TICKET_CODE"
echo "[harness] artifacts=$ARTIFACT_DIR"
