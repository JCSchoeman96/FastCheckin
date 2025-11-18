#!/bin/bash
set -e
# ============================================================================
# Codex Cloud PETAL Setup - Network Bypass Edition
# ============================================================================

echo "🔧 [Codex] Starting Setup..."

# 1. Install Hex from the local file you just pushed (Bypasses download blockers)
echo "📦 [Step 1] Installing Hex from local file..."
mix archive.install vendor/hex.ez --force

# 2. Configure the Mirror (Fixes 'mix deps.get' network issues)
echo "🌐 [Step 2] Configuring Hex mirror..."
mix local.hex --force --remove
mix hex.repo add upyun https://hexpm.upyun.com --fetch-public-key

# 3. Fetch Dependencies (This will now work!)
echo "📥 [Step 3] Fetching dependencies..."
mix deps.get

# --- Standard Build Steps ---
echo "⚙️  Compiling..."
mix deps.compile
mix compile

echo "✅ Setup Complete! Hex is installed and dependencies are fetched."
