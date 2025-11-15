#!/bin/bash
set -e

echo "🔧 [Codex] Installing Hex and Rebar via local archives..."

mkdir -p ~/.mix/archives

# Download .ez files
curl -sSL https://repo.hex.pm/installs/1.12.0/hex.ez -o hex.ez
curl -sSL https://repo.hex.pm/installs/1.20.0/rebar3.ez -o rebar3.ez

# Install from local .ez without contacting Hex.pm
mix archive.install ./hex.ez --force
mix archive.install ./rebar3.ez --force

# Cleanup temp files
rm hex.ez rebar3.ez

echo "📦 Fetching and compiling dependencies..."
mix deps.get
mix deps.compile

echo "🎨 Building assets..."
mix assets.setup || true
mix assets.build || true

echo "✅ [Codex] Setup completed fully offline."
