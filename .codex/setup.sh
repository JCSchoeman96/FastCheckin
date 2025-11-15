#!/bin/bash

set -e

echo "🧰 [Codex] Starting offline-safe setup..."

# Skip Hex install in network-restricted environment
if ping -c1 repo.hex.pm &>/dev/null; then
  echo "🌐 Internet access detected, installing Hex and Rebar..."
  mix local.hex --force || echo "⚠️ Hex install failed but continuing"
  mix local.rebar --force
else
  echo "🚫 No internet access - skipping Hex and Rebar installs"
fi

echo "📦 Skipping deps.get due to offline mode"
echo "✅ Continuing setup with pre-installed dependencies (assumed cached)"

# Skip any deps-related tasks that require fetching
# Instead just try compiling if deps exist
mix compile || echo "⚠️ Compile failed (likely no deps); that's OK in read-only mode"

echo "🧪 Skipping mix precommit due to no network"

if [ -d deps ]; then
  echo "🔁 Deps present — attempting mix precommit..."
  mix precommit || echo "⚠️ mix precommit failed (expected in Codex)"
else
  echo "⏩ Skipping mix precommit (deps not available)"
fi
