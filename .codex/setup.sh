#!/bin/bash

set -e

echo "🧰 [Codex] Starting offline-safe setup..."

if ping -c1 repo.hex.pm &>/dev/null; then
  ONLINE=1
  echo "🌐 Internet access detected, installing Hex and Rebar..."
  mix local.hex --force || echo "⚠️ Hex install failed but continuing"
  mix local.rebar --force
else
  ONLINE=0
  echo "🚫 No internet access - skipping Hex and Rebar installs"
fi

if [ "${ONLINE:-0}" -eq 1 ]; then
  echo "📦 Fetching and compiling dependencies..."
  mix deps.get
  mix deps.compile

  echo "🎨 Setting up assets..."
  mix assets.setup
  mix assets.build

  echo "🧪 Running mix precommit..."
  mix precommit || echo "⚠️ mix precommit failed (expected in Codex)"
else
  echo "📦 Skipping deps.get due to offline mode"
  echo "✅ Continuing setup with pre-installed dependencies (assumed cached)"

  if [ -d deps ]; then
    echo "🔁 Deps present — attempting compile and precommit..."
    mix compile || echo "⚠️ Compile failed (likely no deps); that's OK in read-only mode"
    mix precommit || echo "⚠️ mix precommit failed (expected in Codex)"
  else
    echo "⏩ Skipping compile/precommit (deps not available)"
  fi
fi
