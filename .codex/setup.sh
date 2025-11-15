#!/bin/bash
set -e

echo "🔧 [Codex] Installing Hex from GitHub (bypassing Hex.pm)..."

# Install Hex via GitHub to avoid 503s from Hex CDN
mix archive.install github hexpm/hex --branch latest --force

echo "🛠️ Installing Rebar..."
mix local.rebar --force

echo "📦 Fetching and compiling dependencies..."
mix deps.get
mix deps.compile

echo "🎨 Building assets..."
mix assets.setup || true
mix assets.build || true

echo "✅ [Codex] Setup complete."
