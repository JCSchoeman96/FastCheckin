#!/bin/bash

set -e

echo "🔧 [Codex] Installing Hex and Rebar..."

mix local.hex --force
mix local.rebar --force

echo "📦 Fetching and compiling dependencies..."
mix deps.get
mix deps.compile

echo "🎨 Installing Tailwind & Esbuild (if missing)..."
mix assets.setup || true
mix assets.build || true

echo "✅ [Codex] Setup complete."
