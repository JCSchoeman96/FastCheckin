#!/bin/bash
set -e
# ============================================================================
# Codex Cloud PETAL Setup - Community Solution (The "Manual Install" Method)
# Reference: https://community.openai.com/t/codex-cloud-issues/1364544
# ============================================================================

echo "🔧 [Codex] Starting Setup..."

# 1. Ensure Runtimes (Optional if container already has them, but safe to run)
echo "📦 [Step 1] Verifying Runtime Environment..."
if command -v mise &>/dev/null; then
  mise install erlang@27.2 elixir@1.18.4-otp-27
  eval "$(mise activate bash)"
fi

# 2. Install Hex from Source (We know this works for you)
echo "📦 [Step 2] Installing Hex..."
mix archive.install github hexpm/hex branch latest --force

# 3. MANUALLY Install Rebar3 (The "Rebar Trap" Fix)
# Mix usually downloads this from Hex.pm (which is blocked).
# We use curl to download it manually, bypassing the blockage.
echo "📦 [Step 3] Manually installing Rebar3..."
mkdir -p "$HOME/.mix"
curl -fSL https://github.com/erlang/rebar3/releases/latest/download/rebar3 -o "$HOME/.mix/rebar3"
chmod +x "$HOME/.mix/rebar3"
mix local.rebar rebar3 "$HOME/.mix/rebar3" --force

# 4. Configure Environment (The "Nuclear" Network Fixes)
echo "🛡️  [Step 4] configuring Network Environment..."
# Use UpYun mirror via ENV VAR (More robust than mix hex.repo add)
export HEX_MIRROR="https://hexpm.upyun.com"
# Disable SSL verification (Fixes "Unknown CA" from proxy)
export HEX_UNSAFE_HTTPS=1
# Point Mix to our manual Rebar install
export MIX_REBAR3="$HOME/.mix/rebar3"

# 5. Reset Lockfile
echo "🔓 [Step 5] Cleaning lockfile to force mirror usage..."
rm -f mix.lock

# 6. Fetch Dependencies
echo "📥 [Step 6] Fetching dependencies..."
mix deps.get

# 7. MANUALLY Download Tailwind (Proactive Fix)
# mix tailwind.install will fail for the same reasons as Hex.
# We download the binary manually now to save you the next headache.
echo "🎨 [Step 7] Manually installing Tailwind..."
TAILWIND_VERSION=3.4.3 # Stuck to v3 for stability unless you need v4
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
