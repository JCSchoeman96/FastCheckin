#!/bin/bash
set -e
# ============================================================================
# Codex Cloud PETAL Setup - Final
# ============================================================================

echo "🔧 [Codex] Starting Setup..."

# 1. Install Hex from the local file you pushed
echo "📦 [Step 1] Installing Hex from local file..."
mix archive.install vendor/hex.ez --force

# 2. Configure the Mirror (This is the new, corrected step)
echo "🌐 [Step 2] Configuring Hex mirror..."
# We don't run 'mix local.hex'.
# We just tell the Hex we just installed to remove the default repo
# and add the mirror.
mix hex.repo remove hexpm --force
mix hex.repo add upyun https://hexpm.upyun.com --fetch-public-key

# 3. Fetch Dependencies (This will now use the UpYun mirror)
echo "📥 [Step 3] Fetching dependencies..."
mix deps.get

# --- Standard Build Steps ---
echo "⚙️  Compiling..."
mix deps.compile
mix compile

echo "✅ Setup Complete!"
