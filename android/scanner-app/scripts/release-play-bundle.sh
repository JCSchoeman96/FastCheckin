#!/usr/bin/env bash
# Bumps Play Store versionCode, builds a signed release AAB, and prints upload paths.
#
# Usage:
#   ./scripts/release-play-bundle.sh
#   ./scripts/release-play-bundle.sh --version-name 1.0.1
#   ./scripts/release-play-bundle.sh --no-bump
#
# Requires release signing env vars (see app/build.gradle.kts acceptedSigning* keys).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/version.properties"
OUTPUT_AAB="$ROOT_DIR/app/build/outputs/bundle/release/app-release.aab"

BUMP_VERSION_CODE=1
VERSION_NAME_OVERRIDE=""

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version-name)
      VERSION_NAME_OVERRIDE="${2:?--version-name requires a value}"
      shift 2
      ;;
    --no-bump)
      BUMP_VERSION_CODE=0
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage 1
      ;;
  esac
done

require_file() {
  [[ -f "$1" ]] || {
    echo "Missing required file: $1" >&2
    exit 1
  }
}

read_property() {
  local name="$1"
  local value
  value="$(grep -E "^${name}=" "$VERSION_FILE" | tail -1 | cut -d= -f2- | tr -d '\r')"
  if [[ -z "$value" ]]; then
    echo "Missing $name in $VERSION_FILE" >&2
    exit 1
  fi
  printf '%s' "$value"
}

write_property() {
  local name="$1"
  local value="$2"
  if grep -qE "^${name}=" "$VERSION_FILE"; then
    sed -i "s/^${name}=.*/${name}=${value}/" "$VERSION_FILE"
  else
    printf '%s=%s\n' "$name" "$value" >>"$VERSION_FILE"
  fi
}

log() {
  printf '[play-release] %s\n' "$*"
}

main() {
  require_file "$VERSION_FILE"

  local version_code version_name
  version_code="$(read_property versionCode)"
  version_name="$(read_property versionName)"

  if [[ -n "$VERSION_NAME_OVERRIDE" ]]; then
    version_name="$VERSION_NAME_OVERRIDE"
    write_property versionName "$version_name"
    log "Set versionName=$version_name"
  fi

  if [[ "$BUMP_VERSION_CODE" == "1" ]]; then
    if ! [[ "$version_code" =~ ^[0-9]+$ ]]; then
      echo "Invalid versionCode in $VERSION_FILE: $version_code" >&2
      exit 1
    fi
    version_code=$((version_code + 1))
    write_property versionCode "$version_code"
    log "Bumped versionCode -> $version_code"
  else
    log "Keeping versionCode=$version_code (--no-bump)"
  fi

  log "Building release bundle (versionName=$version_name, versionCode=$version_code)"
  (
    cd "$ROOT_DIR"
    ./gradlew :app:bundleRelease -PFASTCHECK_API_TARGET=release
  )

  require_file "$OUTPUT_AAB"

  log "Release bundle ready:"
  log "  AAB: $OUTPUT_AAB"
  log "  versionCode: $version_code"
  log "  versionName: $version_name"
  log "  package: coza.voelgoed.fastcheck"
  log ""
  log "Upload $OUTPUT_AAB in Play Console (Production or your target track)."
  log "Commit $VERSION_FILE if this bump should be kept in git."
}

main "$@"
