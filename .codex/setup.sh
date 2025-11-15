#!/bin/bash
set -e

echo "🔧 [Codex] Installing Hex directly via .ez fallback..."

mkdir -p ~/.mix/archives

# Download specific Hex version directly — skips metadata fetch
curl -sSL https://repo.hex.pm/installs/1.12.0/hex.ez -o ~/.mix/archives/hex-1.12.0.ez

echo "🛠️ Installing Rebar..."
mix local.rebar --force

echo "📦 Fetching and compiling dependencies..."
mix deps.get
mix deps.compile

echo "🎨 Building assets..."
mix assets.setup || true
mix assets.build || true

echo "✅ [Codex] Setup complete."
