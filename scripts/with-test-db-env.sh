#!/usr/bin/env bash
set -euo pipefail

if [[ "$-" == *x* ]]; then
  printf 'Refusing to load database credentials while Bash xtrace is enabled.\n' >&2
  exit 2
fi

if (($# == 0)); then
  printf 'Usage: %s <command> [args...]\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

credential_file="${DEVCORE_PROJECT_DB_ENV_FILE:-${XDG_CONFIG_HOME:-${HOME:?HOME must be set}/.config}/dev-core/project-db.env}"

if [[ -z "${FASTCHECK_TEST_DB_PASSWORD:-}" && ! -r "$credential_file" ]]; then
  printf 'FastCheck TEST credentials are missing. Expected FASTCHECK_TEST_DB_PASSWORD in %s.\n' \
    "$credential_file" >&2
  exit 1
fi

(
  if [[ -z "${FASTCHECK_TEST_DB_PASSWORD:-}" ]]; then
    source "$credential_file"
  fi

  if [[ -z "${FASTCHECK_TEST_DB_PASSWORD:-}" ]]; then
    printf 'FASTCHECK_TEST_DB_PASSWORD is missing from the credential file.\n' >&2
    exit 1
  fi

  export FASTCHECK_TEST_DB_PASSWORD
  exec "$@"
)
