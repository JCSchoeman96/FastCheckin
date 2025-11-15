#!/bin/bash
set -euo pipefail

MIX_HOME=${MIX_HOME:-"$HOME/.mix"}
HEX_ARCHIVE_DIR="$MIX_HOME/archives"
HEX_VERSION="1.12.0"
HEX_ARCHIVE="$HEX_ARCHIVE_DIR/hex-${HEX_VERSION}.ez"
HEX_URL="https://repo.hex.pm/installs/${HEX_VERSION}/hex.ez"

if ! ping -c1 repo.hex.pm &>/dev/null; then
  echo "⚠️ No internet access — skipping Hex install and dependency fetches."
  exit 0
fi

echo "🔧 Installing Hex package manager..."
if ! mix local.hex --force 2>/dev/null; then
  echo "⚠️ Hex auto-install failed, using direct URL install..."
  mkdir -p "$HEX_ARCHIVE_DIR"
  curl -sSL "$HEX_URL" -o "$HEX_ARCHIVE"
  mix archive.install --force "$HEX_ARCHIVE"
fi

echo "🔨 Installing Rebar..."
mix local.rebar --force

echo "📦 Fetching and compiling dependencies..."
mix deps.get
mix deps.compile

echo "🎨 Installing TailwindCSS and Esbuild (if missing)..."
mix assets.setup

echo "⚙️ Running initial setup (DB + assets)..."
mix setup
