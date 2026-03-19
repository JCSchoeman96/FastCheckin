#!/bin/sh
set -eu

if [ "${RUN_MIGRATIONS:-true}" = "true" ]; then
  /app/bin/fastcheck eval "FastCheck.Release.migrate()"
fi

exec /app/bin/fastcheck start
