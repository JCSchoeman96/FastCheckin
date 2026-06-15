#!/usr/bin/env bash
# FastCheck Play Store screenshot capture — starts a local API (optional), seeds demo
# data, runs PlayStoreScreenshotTest on phone / 7" / 10" emulators, and normalizes
# PNGs to Google Play aspect-ratio requirements.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
OUTPUT_ROOT="$ROOT_DIR/play-store-listing"
ANDROID_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
ADB="$ANDROID_SDK/platform-tools/adb"
EMULATOR="$ANDROID_SDK/emulator/emulator"
AVDMANAGER="$ANDROID_SDK/cmdline-tools/latest/bin/avdmanager"
SYSTEM_IMAGE="system-images;android-36.1;google_apis_playstore;x86_64"

CREDENTIAL="${FASTCHECK_PLAY_CREDENTIAL:-play-screenshots}"
ATTENDEE_COUNT="${FASTCHECK_PLAY_ATTENDEES:-50}"
EVENT_NAME="${FASTCHECK_PLAY_EVENT_NAME:-FastCheck Demo Event}"
API_TARGET="${FASTCHECK_API_TARGET:-dev}"
API_BASE_URL_DEV="${FASTCHECK_API_BASE_URL_DEV:-http://10.0.2.2:4003/}"
PHOENIX_PORT="${FASTCHECK_PLAY_PHOENIX_PORT:-4003}"
START_PHOENIX="${FASTCHECK_PLAY_START_PHOENIX:-1}"
FORM_FACTORS="${FASTCHECK_PLAY_FORM_FACTORS:-phone,tablet-7in,tablet-10in}"

PHONE_AVD="${FASTCHECK_PLAY_PHONE_AVD:-Medium_Phone_API_36.1}"
TABLET_7_AVD="${FASTCHECK_PLAY_TABLET_7_AVD:-FastCheck_Tablet_7in_API_36}"
TABLET_10_AVD="${FASTCHECK_PLAY_TABLET_10_AVD:-FastCheck_Tablet_10in_API_36}"

PHONE_SIZE="1080x1920"
TABLET_7_SIZE="1200x2133"
TABLET_10_SIZE="1440x2560"

PHOENIX_PID=""
EMULATOR_PID=""
EVENT_ID=""

log() {
  printf '[play-screenshots] %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

cleanup() {
  if [[ -n "$EMULATOR_PID" ]] && kill -0 "$EMULATOR_PID" 2>/dev/null; then
    kill "$EMULATOR_PID" 2>/dev/null || true
    wait "$EMULATOR_PID" 2>/dev/null || true
  fi
  if [[ -n "$PHOENIX_PID" ]] && kill -0 "$PHOENIX_PID" 2>/dev/null; then
    kill "$PHOENIX_PID" 2>/dev/null || true
    wait "$PHOENIX_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

normalize_png() {
  local input="$1"
  local output="$2"
  local size="$3"
  local width="${size%x*}"
  local height="${size#*x}"

  ffmpeg -y -loglevel error -i "$input" \
    -vf "scale=${width}:${height}:force_original_aspect_ratio=increase,crop=${width}:${height}" \
    "$output"
}

ensure_avd() {
  local name="$1"
  local device_id="$2"

  if "$AVDMANAGER" list avd | grep -q "Name: $name"; then
    return 0
  fi

  log "Creating AVD $name ($device_id)"
  printf 'no\n' | "$AVDMANAGER" create avd \
    -n "$name" \
    -k "$SYSTEM_IMAGE" \
    -d "$device_id" \
    --force
}

wait_for_device() {
  "$ADB" wait-for-device
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if "$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -q '^1$'; then
      local sdk_level
      sdk_level="$("$ADB" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
      if [[ -n "$sdk_level" && "$sdk_level" =~ ^[0-9]+$ ]]; then
        "$ADB" shell settings put global window_animation_scale 0 >/dev/null 2>&1 || true
        "$ADB" shell settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
        "$ADB" shell settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
        sleep 3
        return 0
      fi
    fi
    sleep 2
  done
  echo "Timed out waiting for emulator boot." >&2
  exit 1
}

start_emulator() {
  local avd_name="$1"
  local skin_size="$2"

  log "Starting emulator $avd_name ($skin_size)"
  "$EMULATOR" -avd "$avd_name" -no-audio -no-boot-anim -gpu swiftshader_indirect \
    -skin "$skin_size" -port 5554 >/tmp/fastcheck-play-emulator.log 2>&1 &
  EMULATOR_PID=$!
  wait_for_device
}

stop_emulator() {
  if [[ -n "$EMULATOR_PID" ]] && kill -0 "$EMULATOR_PID" 2>/dev/null; then
    "$ADB" emu kill >/dev/null 2>&1 || true
    wait "$EMULATOR_PID" 2>/dev/null || true
  fi
  EMULATOR_PID=""
}

start_phoenix_if_needed() {
  if [[ "$API_TARGET" == "release" || "$API_TARGET" == "device" || "$START_PHOENIX" != "1" ]]; then
    return 0
  fi

  if curl -fsS "http://127.0.0.1:${PHOENIX_PORT}/api/v1/health" >/dev/null 2>&1; then
    log "Phoenix already running on :$PHOENIX_PORT"
    return 0
  fi

  log "Starting Phoenix on :$PHOENIX_PORT"
  (
    cd "$REPO_ROOT"
    PORT="$PHOENIX_PORT" MIX_ENV=dev mix phx.server
  ) >/tmp/fastcheck-play-phoenix.log 2>&1 &
  PHOENIX_PID=$!

  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if curl -fsS "http://127.0.0.1:${PHOENIX_PORT}/api/v1/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "Timed out waiting for Phoenix on :$PHOENIX_PORT. See /tmp/fastcheck-play-phoenix.log" >&2
  exit 1
}

seed_demo_event() {
  if [[ -n "${FASTCHECK_PLAY_EVENT_ID:-}" ]]; then
    EVENT_ID="$FASTCHECK_PLAY_EVENT_ID"
    log "Using provided event id $EVENT_ID"
    return 0
  fi

  if [[ "$API_TARGET" == "emulator" || "$API_TARGET" == "dev" ]]; then
    start_phoenix_if_needed
    log "Seeding demo mobile event"
    local seed_output
    seed_output="$(
      cd "$REPO_ROOT"
      PORT="$PHOENIX_PORT" mix fastcheck.load.seed_mobile_event \
        --attendees "$ATTENDEE_COUNT" \
        --credential "$CREDENTIAL"
    )"
    EVENT_ID="$(printf '%s\n' "$seed_output" | sed -n 's/^[[:space:]]*event_id:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
    if [[ -z "$EVENT_ID" ]]; then
      echo "Unable to parse seeded event id from mix output:" >&2
      printf '%s\n' "$seed_output" >&2
      exit 1
    fi
    log "Seeded event_id=$EVENT_ID credential=$CREDENTIAL"
    return 0
  fi

  echo "FASTCHECK_PLAY_EVENT_ID is required when FASTCHECK_API_TARGET is release or device." >&2
  exit 1
}

gradle_api_args() {
  local args=(-PFASTCHECK_API_TARGET="$API_TARGET" -PFASTCHECK_SCANNER_SOURCE=camera)
  if [[ "$API_TARGET" == "dev" ]]; then
    args+=(-PFASTCHECK_API_BASE_URL_DEV="$API_BASE_URL_DEV")
  fi
  printf '%s\n' "${args[@]}"
}

run_capture_for_form_factor() {
  local form_factor="$1"
  local avd_name="$2"
  local skin_size="$3"
  local target_size="$4"
  local raw_dir="$OUTPUT_ROOT/raw/$form_factor"
  local final_dir="$OUTPUT_ROOT/$form_factor"

  mkdir -p "$raw_dir" "$final_dir"
  start_emulator "$avd_name" "$skin_size"

  log "Installing debug APK and capturing $form_factor screenshots"
  local -a gradle_args
  mapfile -t gradle_args < <(gradle_api_args)

  (
    cd "$ROOT_DIR"
    ./gradlew installDebug installDebugAndroidTest "${gradle_args[@]}" \
      >/tmp/fastcheck-play-gradle-install.log 2>&1
  )

  log "Running PlayStoreScreenshotTest on device"
  "$ADB" shell am instrument -w -r \
    -e class za.co.voelgoed.fastcheck.app.PlayStoreScreenshotTest \
    -e fastcheck.integration true \
    -e fastcheck.eventId "$EVENT_ID" \
    -e fastcheck.credential "$CREDENTIAL" \
    -e fastcheck.formFactor "$form_factor" \
    coza.voelgoed.fastcheck.test/za.co.voelgoed.fastcheck.app.HiltTestRunner \
    >/tmp/fastcheck-play-instrument-$form_factor.log 2>&1

  if ! grep -q "OK (1 test)" /tmp/fastcheck-play-instrument-$form_factor.log; then
    echo "Instrumentation failed for $form_factor. See /tmp/fastcheck-play-instrument-$form_factor.log" >&2
    exit 1
  fi

  local device_dir="files/play-store-screenshots/$form_factor"
  rm -f "$raw_dir"/*.png
  mkdir -p "$raw_dir"

  mapfile -t remote_files < <(
    "$ADB" shell run-as coza.voelgoed.fastcheck ls "$device_dir" 2>/dev/null \
      | tr -d '\r' \
      | grep '\.png$' || true
  )

  if ((${#remote_files[@]} == 0)); then
    echo "No screenshots found on device for $form_factor. See /tmp/fastcheck-play-instrument-$form_factor.log" >&2
    exit 1
  fi

  for remote_name in "${remote_files[@]}"; do
    local base_name pulled
    base_name="$(basename "$remote_name")"
    pulled="$raw_dir/$base_name"
    "$ADB" exec-out run-as coza.voelgoed.fastcheck cat "$device_dir/$base_name" >"$pulled"
    normalize_png "$pulled" "$final_dir/$base_name" "$target_size"
    log "Wrote $final_dir/$base_name ($target_size)"
  done

  "$ADB" shell pm clear coza.voelgoed.fastcheck >/dev/null 2>&1 || true
  stop_emulator
}

main() {
  require_cmd ffmpeg
  require_cmd curl
  require_cmd mix

  mkdir -p "$OUTPUT_ROOT/raw" "$OUTPUT_ROOT/phone" "$OUTPUT_ROOT/tablet-7in" "$OUTPUT_ROOT/tablet-10in"

  ensure_avd "$TABLET_7_AVD" "Nexus 7"
  ensure_avd "$TABLET_10_AVD" "pixel_tablet"

  seed_demo_event

  IFS=',' read -r -a form_factor_list <<<"$FORM_FACTORS"
  for form_factor in "${form_factor_list[@]}"; do
    case "$form_factor" in
      phone)
        run_capture_for_form_factor "phone" "$PHONE_AVD" "$PHONE_SIZE" "$PHONE_SIZE"
        ;;
      tablet-7in)
        run_capture_for_form_factor "tablet-7in" "$TABLET_7_AVD" "$TABLET_7_SIZE" "$TABLET_7_SIZE"
        ;;
      tablet-10in)
        run_capture_for_form_factor "tablet-10in" "$TABLET_10_AVD" "$TABLET_10_SIZE" "$TABLET_10_SIZE"
        ;;
      *)
        echo "Unknown form factor '$form_factor'. Expected phone, tablet-7in, or tablet-10in." >&2
        exit 1
        ;;
    esac
  done

  log "Done. Upload-ready screenshots:"
  log "  Phone:      $OUTPUT_ROOT/phone"
  log "  7-inch:     $OUTPUT_ROOT/tablet-7in"
  log "  10-inch:    $OUTPUT_ROOT/tablet-10in"
}

main "$@"
