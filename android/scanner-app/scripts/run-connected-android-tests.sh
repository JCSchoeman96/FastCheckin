#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER_APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_AVD_NAME="Medium_Phone_API_36"
DEFAULT_SYSTEM_IMAGE="system-images;android-36;google_apis;x86_64"
DEFAULT_DEVICE_PROFILE="medium_phone"
DEFAULT_GRADLE_TASK=":app:connectedDebugAndroidTest"
EMULATOR_FLAGS=(-no-window -gpu swiftshader_indirect -no-snapshot -no-boot-anim -no-audio -netfast)

AVD_NAME="$DEFAULT_AVD_NAME"
SYSTEM_IMAGE="$DEFAULT_SYSTEM_IMAGE"
DEVICE_PROFILE="$DEFAULT_DEVICE_PROFILE"
GRADLE_TASK="$DEFAULT_GRADLE_TASK"
TEST_CLASS=""
GRADLE_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  run-connected-android-tests.sh [options] [-- <extra gradle args>]

Options:
  --class <fqcn>         Instrumentation test class to run
  --task <gradle_task>   Gradle task to run (default: :app:connectedDebugAndroidTest)
  --avd <name>           AVD name to create/use (default: Medium_Phone_API_36)
  --system-image <path>  SDK system image package (default: system-images;android-36;google_apis;x86_64)
  --device <id>          AVD device profile id (default: medium_phone)
  --help                 Show this help

Examples:
  ./scripts/run-connected-android-tests.sh
  ./scripts/run-connected-android-tests.sh --class za.co.voelgoed.fastcheck.app.MainActivityCameraRecoveryFlowTest
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class)
      TEST_CLASS="$2"
      shift 2
      ;;
    --task)
      GRADLE_TASK="$2"
      shift 2
      ;;
    --avd)
      AVD_NAME="$2"
      shift 2
      ;;
    --system-image)
      SYSTEM_IMAGE="$2"
      shift 2
      ;;
    --device)
      DEVICE_PROFILE="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    --)
      shift
      GRADLE_ARGS+=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

resolve_sdk_root() {
  if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    echo "$ANDROID_SDK_ROOT"
    return
  fi

  if [[ -n "${ANDROID_HOME:-}" ]]; then
    echo "$ANDROID_HOME"
    return
  fi

  if [[ -d "$HOME/Android/Sdk" ]]; then
    echo "$HOME/Android/Sdk"
    return
  fi

  echo "Unable to locate Android SDK. Set ANDROID_SDK_ROOT or ANDROID_HOME." >&2
  exit 1
}

SDK_ROOT="$(resolve_sdk_root)"
export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_HOME="$SDK_ROOT"
export PATH="$SDK_ROOT/platform-tools:$SDK_ROOT/emulator:$SDK_ROOT/cmdline-tools/latest/bin:$PATH"

for tool in adb emulator avdmanager sdkmanager; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required Android tool: $tool" >&2
    exit 1
  fi
done

SYSTEM_IMAGE_DIR="${SYSTEM_IMAGE//;/\/}"
if [[ ! -d "$SDK_ROOT/$SYSTEM_IMAGE_DIR" ]]; then
  echo "Installing missing system image: $SYSTEM_IMAGE"
  yes | sdkmanager "$SYSTEM_IMAGE"
fi

if ! emulator -list-avds | grep -Fxq "$AVD_NAME"; then
  echo "Creating AVD: $AVD_NAME"
  printf 'no\n' | avdmanager create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" -d "$DEVICE_PROFILE"
fi

echo "Restarting ADB server"
adb kill-server >/dev/null 2>&1 || true
adb start-server >/dev/null

running_emulators=()
while read -r serial _; do
  [[ "$serial" == emulator-* ]] || continue
  running_emulators+=("$serial")
done < <(adb devices)

if [[ "${#running_emulators[@]}" -gt 0 ]]; then
  echo "Stopping running emulators: ${running_emulators[*]}"
  for serial in "${running_emulators[@]}"; do
    adb -s "$serial" emu kill >/dev/null 2>&1 || true
  done
fi

for _ in $(seq 1 60); do
  active_count="$(adb devices | awk '/^emulator-[0-9]+\t/{count++} END {print count+0}')"
  if [[ "$active_count" == "0" ]]; then
    break
  fi
  sleep 1
done

EMULATOR_LOG="/tmp/${AVD_NAME}.emulator.log"
echo "Starting emulator $AVD_NAME"
nohup emulator @"$AVD_NAME" "${EMULATOR_FLAGS[@]}" >"$EMULATOR_LOG" 2>&1 &

SERIAL=""
for _ in $(seq 1 180); do
  SERIAL="$(adb devices | awk '/^emulator-[0-9]+\tdevice/{print $1; exit}')"
  if [[ -n "$SERIAL" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "$SERIAL" ]]; then
  echo "Emulator did not register with adb. See $EMULATOR_LOG" >&2
  exit 1
fi

echo "Waiting for $SERIAL to boot"
for _ in $(seq 1 180); do
  boot_completed="$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
  if [[ "$boot_completed" == "1" ]]; then
    break
  fi
  sleep 2
done

boot_completed="$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
if [[ "$boot_completed" != "1" ]]; then
  echo "Emulator failed to finish booting. See $EMULATOR_LOG" >&2
  exit 1
fi

sdk_level="$(adb -s "$SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')"
if [[ "$sdk_level" != "36" ]]; then
  echo "Connected emulator reports unexpected SDK level '$sdk_level'. Use a stable API 36 AVD for connected tests." >&2
  exit 1
fi

adb -s "$SERIAL" shell input keyevent 82 >/dev/null 2>&1 || true

echo "Running $GRADLE_TASK on $SERIAL (API $sdk_level)"
# Keep connected-test execution deterministic by pinning Gradle to the emulator
# started by this script. Without this, attached USB devices can also be picked
# by connectedDebugAndroidTest and cause mixed-target, non-reproducible results.
export ANDROID_SERIAL="$SERIAL"
gradle_cmd=("./gradlew" "$GRADLE_TASK" "--no-daemon")
if [[ -n "$TEST_CLASS" ]]; then
  gradle_cmd+=("-Pandroid.testInstrumentationRunnerArguments.class=$TEST_CLASS")
fi
if [[ "${#GRADLE_ARGS[@]}" -gt 0 ]]; then
  gradle_cmd+=("${GRADLE_ARGS[@]}")
fi

(cd "$SCANNER_APP_DIR" && "${gradle_cmd[@]}")
