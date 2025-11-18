#!/bin/bash
set -e
# ============================================================================
# Codex Cloud PETAL Setup - Final
#
# Strategy:
# 1. Have the container itself build Hex from the GitHub source.
#    This solves the "corrupt atom table" (version mismatch) error.
# 2. Configure the mirror to fix 'mix deps.get' network errors.
# ============================================================================

echo "🔧 [Codex] Starting Setup..."

# 1. Install Hex from GitHub source code.
# This clones the repo and builds it *inside* the container,
# ensuring it matches the container's Elixir/OTP version.
echo "📦 [Step 1] Building Hex from source..."
mix archive.install github hexpm/hex branch latest --force

# 2. Configure the Mirror for project dependencies
echo "🌐 [Step 2] Configuring Hex mirror..."
# We remove the default 'hexpm' repo that is blocked by the proxy
mix hex.repo remove hexpm --force
# We add the UpYun mirror that is known to work
mix hex.repo add upyun https://hexpm.upyun.com --fetch-public-key

# 3. Fetch Dependencies (This will now use the UpYun mirror)
echo "📥 [Step 3] Fetching dependencies..."
mix deps.get

# --- Standard Build Steps ---
echo "⚙️  Compiling..."
mix deps.compile
mix compile

echo "✅ Setup Complete!"
