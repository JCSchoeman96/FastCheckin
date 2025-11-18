#!/bin/bash
set -e
# ============================================================================
# Codex Cloud PETAL Setup - Final
#
# Strategy:
# 1. Build Hex from source to match the container's Elixir/OTP version.
# 2. Configure the UpYun mirror (without the failing flag).
# ============================================================================

echo "🔧 [Codex] Starting Setup..."

# 1. Install Hex from GitHub source code.
echo "📦 [Step 1] Building Hex from source..."
mix archive.install github hexpm/hex branch latest --force

# 2. Configure the Mirror for project dependencies
echo "🌐 [Step 2] Configuring Hex mirror..."
mix hex.repo remove hexpm --force

# This is the corrected line:
mix hex.repo add upyun https://hexpm.upyun.com

# 3. Fetch Dependencies (This will now use the UpYun mirror)
echo "📥 [Step 3] Fetching dependencies..."
mix deps.get

# --- Standard Build Steps ---
echo "⚙️  Compiling..."
mix deps.compile
mix compile

echo "✅ Setup Complete!"
