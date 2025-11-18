#!/bin/bash
set -e
# ============================================================================
# Codex Cloud PETAL Setup - Final Fix
# ============================================================================

echo "🔧 [Codex] Starting Setup..."

# --- Fix 1: Update SSL Certificates ---
# This fixes the "Fatal - Unknown CA" errors by updating the system's trust store.
echo "📜 Updating SSL certificates..."
if command -v apt-get &>/dev/null; then
    apt-get update -y && apt-get install -y ca-certificates
fi
if command -v update-ca-certificates &>/dev/null; then
    update-ca-certificates --fresh
fi

# --- Step 1: Build Hex from Source ---
# (This part is working, we keep it)
echo "📦 [Step 1] Building Hex from source..."
mix archive.install github hexpm/hex branch latest --force

# --- Fix 2: Configure Mirror & Reset Lockfile ---
echo "🌐 [Step 2] Configuring Hex mirror..."
mix hex.repo remove hexpm --force || true
mix hex.repo add upyun https://hexpm.upyun.com

# IMPORTANT: Delete mix.lock to stop Mix from trying to use the old 'hexpm' repo
echo "🔓 [Step 3] Removing mix.lock to force mirror usage..."
rm -f mix.lock

# --- Step 3: Fetch & Build ---
echo "📥 [Step 4] Fetching dependencies..."
# If SSL still fails, we try one last fallback: insecure mode (uncomment if needed)
# export HEX_UNSAFE_HTTPS=1 
mix deps.get

echo "⚙️  Compiling..."
mix deps.compile
mix compile

echo "✅ Setup Complete!"
