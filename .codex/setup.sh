#!/bin/bash
set -e
# ============================================================================
# Codex Cloud PETAL Setup - The "Hybrid" Solution
# Combines Manual Tool Install (Forum Fix) + SSL Trust Path (Cert Fix)
# ============================================================================

echo "🔧 [Codex] Starting Setup..."

# 1. PREP: Update System Certificates
# We do this first so the system trusts the Codex Proxy.
echo "🛡️  [Step 1] Updating System Certificates..."
if command -v apt-get &>/dev/null; then
    apt-get update -y && apt-get install -y ca-certificates curl
fi
update-ca-certificates --fresh

# 2. RUNTIME: Install Erlang/Elixir via Mise
echo "📦 [Step 2] Verifying Runtime Environment..."
if command -v mise &>/dev/null; then
  mise install erlang@27.2 elixir@1.18.4-otp-27
  eval "$(mise activate bash)"
fi

# 3. HEX: Build from source (Bypasses version errors)
echo "📦 [Step 3] Installing Hex..."
mix archive.install github hexpm/hex branch latest --force

# 4. REBAR: Manually Install (Bypasses 'mix local.rebar' network block)
echo "📦 [Step 4] Manually installing Rebar3..."
mkdir -p "$HOME/.mix"
curl -fSL https://github.com/erlang/rebar3/releases/latest/download/rebar3 -o "$HOME/.mix/rebar3"
chmod +x "$HOME/.mix/rebar3"
mix local.rebar rebar3 "$HOME/.mix/rebar3" --force

# 5. NETWORK: The Critical Fixes
echo "🌐 [Step 5] Configuring Network & SSL..."
# A. Point Erlang to the system certs we just updated (FIXES 'Unknown CA')
export HEX_CACERTS_PATH="/etc/ssl/certs/ca-certificates.crt"

# B. Force UpYun Mirror (Bypasses 'repo.hex.pm' 503 block)
export HEX_MIRROR="https://hexpm.upyun.com"

# C. Safety Net: Ignore SSL errors if the proxy cert is still weird
export HEX_UNSAFE_HTTPS=1

# D. Point to our manual Rebar
export MIX_REBAR3="$HOME/.mix/rebar3"

# 6. DEPENDENCIES: Fetch
echo "📥 [Step 6] Fetching dependencies..."
# Force-clean any old locks
rm -f mix.lock
mix deps.get

# 7. TAILWIND: Manual Pre-install
echo "🎨 [Step 7] Manually installing Tailwind..."
TAILWIND_VERSION=3.4.3
TARGET="linux-x64"
TAILWIND_DEST="_build/tailwind-${TARGET}"
mkdir -p "$(dirname "$TAILWIND_DEST")"
curl -fSL "https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}/tailwindcss-${TARGET}" -o "$TAILWIND_DEST"
chmod +x "$TAILWIND_DEST"

# --- Standard Build Steps ---
echo "⚙️  Compiling..."
mix deps.compile
mix compile

echo "✅ Setup Complete!"
