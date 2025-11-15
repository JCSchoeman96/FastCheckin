#!/bin/bash
set -euo pipefail

echo "🔧 Installing Hex and Rebar..."
mix local.hex --force
mix local.rebar --force

echo "📦 Fetching and compiling dependencies..."
mix deps.get
mix deps.compile

echo "🎨 Installing TailwindCSS and Esbuild (if missing)..."
mix assets.setup

echo "⚙️ Running initial setup (DB + assets)..."
mix setup
