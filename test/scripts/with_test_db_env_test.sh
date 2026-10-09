#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
wrapper="$repo_root/scripts/with-test-db-env.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

credential_file="$tmp_dir/project-db.env"
printf '%s\n' \
  'FASTCHECK_TEST_DB_PASSWORD=fake-test-password' \
  'OTHER_PROJECT_TEST_PASSWORD=fake-other-project-password' \
  >"$credential_file"

output="$(DEVCORE_PROJECT_DB_ENV_FILE="$credential_file" "$wrapper" bash -c '
  printf "%s|%s" "${FASTCHECK_TEST_DB_PASSWORD:-}" "${OTHER_PROJECT_TEST_PASSWORD:-}"
')"

if [[ "$output" != 'fake-test-password|' ]]; then
  printf 'Expected the child command to receive only the FastCheck TEST password.\n' >&2
  exit 1
fi

printf 'with-test-db-env wrapper test passed\n'
