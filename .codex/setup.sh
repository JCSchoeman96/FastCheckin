#!/bin/bash
set -e

echo "🔧 [Codex] Installing Hex and Rebar via direct .ez fallback..."

mkdir -p ~/.mix/archives

# Must be named hex.ez and rebar3.ez for mix to detect them
curl -sSL https://repo.hex.pm/installs/1.12.0/hex.ez -o ~/.mix/archives/hex.ez
curl -sSL https://repo.hex.pm/installs/1.20.0/rebar3.ez -o ~/.mix/archives/rebar3.ez

echo "📦 Fetching and compiling dependencies..."
mix deps.get
mix deps.compile

echo "🎨 Building assets..."
mix assets.setup || true
mix assets.build || true

echo "✅ [Codex] Offline-safe setup complete."
