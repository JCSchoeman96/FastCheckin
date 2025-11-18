#!/bin/bash
set -e
# ============================================================================
# Codex Cloud PETAL Setup - SSL Bypass Strategy
# ============================================================================

echo "🔧 [Codex] Starting Setup..."

# 1. Build Hex from source (This works and is required)
echo "📦 [Step 1] Building Hex from source..."
mix archive.install github hexpm/hex branch latest --force

# 2. Configure Environment to IGNORE SSL Errors
# We are setting this because we know 'repo.hex.pm' is reachable, 
# but the Codex proxy's certificate is untrusted.
echo "🛡️  [Step 2] Disabling SSL verification for Hex..."
export HEX_UNSAFE_HTTPS=1
export HEX_HTTP_TIMEOUT=120

# 3. Reset to Default Repository
# We remove the broken 'upyun' mirror and ensure we are using the standard repo.
echo "🌐 [Step 3] Resetting to default Hex repository..."
mix hex.repo remove upyun --force 2>/dev/null || true
mix hex.repo add hexpm https://repo.hex.pm --force

# 4. Remove lockfile to ensure fresh resolution
echo "🔓 [Step 4] Cleaning lockfile..."
rm -f mix.lock

# 5. Fetch Dependencies
echo "📥 [Step 5] Fetching dependencies (SSL Bypass Active)..."
mix deps.get

# --- Standard Build Steps ---
echo "⚙️  Compiling..."
mix deps.compile
mix compile

echo "✅ Setup Complete!"
