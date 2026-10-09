#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
wrapper="$repo_root/scripts/with-test-db-env.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

credential_file="$tmp_dir/project-db.env"
printf '%s\n' \
  'printf "credential-file-noise\\n"' \
  'FASTCHECK_TEST_DB_PASSWORD=fake-test-password' \
  'OTHER_PROJECT_TEST_PASSWORD=fake-other-project-password' \
  >"$credential_file"

output="$(env -u OTHER_PROJECT_TEST_PASSWORD \
  DEVCORE_PROJECT_DB_ENV_FILE="$credential_file" \
  "$wrapper" bash -c '
    printf "%s|%s" "${FASTCHECK_TEST_DB_PASSWORD:-}" "${OTHER_PROJECT_TEST_PASSWORD:-<absent>}"
  '
)"

if [[ "$output" != 'fake-test-password|<absent>' ]]; then
  printf 'Expected normal assignments to provide only the FastCheck TEST password.\n' >&2
  exit 1
fi

printf '%s\n' \
  'FASTCHECK_TEST_DB_PASSWORD=fake-test-password' \
  'export OTHER_PROJECT_TEST_PASSWORD=fake-other-project-password' \
  >"$credential_file"

output="$(env -u OTHER_PROJECT_TEST_PASSWORD \
  DEVCORE_PROJECT_DB_ENV_FILE="$credential_file" \
  "$wrapper" bash -c '
    printf "%s|%s" "${FASTCHECK_TEST_DB_PASSWORD:-}" "${OTHER_PROJECT_TEST_PASSWORD:-<absent>}"
  '
)"

if [[ "$output" != 'fake-test-password|<absent>' ]]; then
  printf 'An exported unrelated credential reached the child command.\n' >&2
  exit 1
fi

printf '%s\n' \
  'set -a' \
  'FASTCHECK_TEST_DB_PASSWORD=fake-test-password' \
  'ANOTHER_PROJECT_SECRET=fake-another-project-secret' \
  'set +a' \
  >"$credential_file"

output="$(env -u ANOTHER_PROJECT_SECRET \
  DEVCORE_PROJECT_DB_ENV_FILE="$credential_file" \
  "$wrapper" bash -c '
    printf "%s|%s" "${FASTCHECK_TEST_DB_PASSWORD:-}" "${ANOTHER_PROJECT_SECRET:-<absent>}"
  '
)"

if [[ "$output" != 'fake-test-password|<absent>' ]]; then
  printf 'A set -a unrelated credential reached the child command.\n' >&2
  exit 1
fi

missing_credential_file="$tmp_dir/missing.env"
output="$(FASTCHECK_TEST_DB_PASSWORD=caller-password \
  DEVCORE_PROJECT_DB_ENV_FILE="$missing_credential_file" \
  "$wrapper" bash -c 'printf "%s" "$FASTCHECK_TEST_DB_PASSWORD"'
)"

if [[ "$output" != 'caller-password' ]]; then
  printf 'Expected the caller password to bypass credential-file loading.\n' >&2
  exit 1
fi

marker_file="$tmp_dir/child-ran"
if output="$(env -u FASTCHECK_TEST_DB_PASSWORD \
  DEVCORE_PROJECT_DB_ENV_FILE="$missing_credential_file" \
  "$wrapper" bash -c 'printf ran >"$1"' _ "$marker_file" 2>&1)"; then
  printf 'Expected a missing credential to fail.\n' >&2
  exit 1
fi

if [[ -e "$marker_file" || "$output" == *'fake-test-password'* || "$output" == *'fake-other-project-password'* ]]; then
  printf 'Missing credentials executed the child or exposed a secret.\n' >&2
  exit 1
fi

malformed_credential_file="$tmp_dir/malformed.env"
printf '%s\n' \
  'set +e' \
  'FASTCHECK_TEST_DB_PASSWORD=fake-test-password' \
  'this is not valid bash {' \
  >"$malformed_credential_file"

malformed_marker_file="$tmp_dir/malformed-child-ran"
if output="$(env -u FASTCHECK_TEST_DB_PASSWORD \
  DEVCORE_PROJECT_DB_ENV_FILE="$malformed_credential_file" \
  "$wrapper" bash -c 'printf ran >"$1"' _ "$malformed_marker_file" 2>&1)"; then
  if [[ -e "$malformed_marker_file" ]]; then
    printf 'Malformed credential authority executed the child command.\n' >&2
  else
    printf 'Malformed credential authority unexpectedly returned success.\n' >&2
  fi
  exit 1
fi

if [[ -e "$malformed_marker_file" || "$output" == *'fake-test-password'* ]]; then
  printf 'Malformed credential authority executed the child or exposed a secret.\n' >&2
  exit 1
fi

if output="$(DEVCORE_PROJECT_DB_ENV_FILE="$missing_credential_file" \
  bash -x "$wrapper" bash -c 'printf ran >"$1"' _ "$marker_file" 2>&1)"; then
  printf 'Expected xtrace-enabled execution to fail.\n' >&2
  exit 1
fi

if [[ -e "$marker_file" || "$output" == *'fake-test-password'* || "$output" == *'fake-other-project-password'* ]]; then
  printf 'Xtrace rejection executed the child or exposed a secret.\n' >&2
  exit 1
fi

printf 'with-test-db-env wrapper test passed\n'
