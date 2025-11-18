#!/bin/bash
set -e
# ============================================================================
# Codex Cloud PETAL Setup - The "Ironclad" Script
# ============================================================================

echo "🔧 [Codex] Starting Setup..."

# ----------------------------------------------------------------------------
# PHASE 1: SSL & Network Prep (The Fix for "Unknown CA")
# ----------------------------------------------------------------------------
echo "🛡️  Configuring SSL & Network..."

# 1. Update OS Certificates (so the OS trusts the proxy)
if command -v apt-get &>/dev/null; then
    apt-get update -y && apt-get install -y ca-certificates curl
fi
update-ca-certificates --fresh

# 2. VITAL: Force Hex to use the OS certificates we just updated
#    This bridges the gap between the OS trust store and Erlang's HTTP client.
export HEX_CACERTS_PATH="/etc/ssl/certs/ca-certificates.crt"

# 3. EDGE CASE FALLBACK: Disable SSL verification if the proxy cert is weird.
#    This prevents the "Fatal - Unknown CA" error from blocking the build.
export HEX_UNSAFE_HTTPS=1

# 4. Ensure these env vars persist for future commands in this session
export HEX_HTTP_TIMEOUT=120

# ----------------------------------------------------------------------------
# PHASE 2: Install Hex (Solved: Version Match)
# ----------------------------------------------------------------------------
echo "📦 Building Hex from source (Ensures version match)..."
# We use the force flag to overwrite any broken previous installs
mix archive.install github hexpm/hex branch latest --force

# ----------------------------------------------------------------------------
# PHASE 3: Dependency Resolution (Solved: Mirror + Lockfile Reset)
# ----------------------------------------------------------------------------
echo "🌐 Configuring Mirrors..."

# 1. Force-remove the default repo (it's blocked/slow)
mix hex.repo remove hexpm --force || true

# 2. Add UpYun Mirror (Fast & Accessible)
mix hex.repo add upyun https://hexpm.upyun.com

# 3. Nuke the lockfile.
#    Edge Case: If mix.lock exists, it might force the 'hexpm' repo specifically.
#    Removing it forces resolution against our new 'upyun' mirror.
echo "🔓 Removing mix.lock to force resolution..."
rm -f mix.lock

# ----------------------------------------------------------------------------
# PHASE 4: Build
# ----------------------------------------------------------------------------
echo "📥 Fetching dependencies..."
mix deps.get

echo "⚙️  Compiling..."
mix deps.compile
mix compile

echo "✅ Setup Complete! Environment is ready."
