#!/usr/bin/env bash
set -euo pipefail

echo "🔧 [Codex] Starting Setup (offline Hex mode)..."

##
## 1. System certs (harmless; leave it)
##
echo "🛡️  [Step 1] Updating System Certificates..."
if command -v apt-get &>/dev/null; then
  apt-get update -y && apt-get install -y ca-certificates curl
fi
update-ca-certificates --fresh || true

##
## 2. Install Erlang/Elixir via mise
##
echo "📦 [Step 2] Verifying Runtime Environment..."
if command -v mise &>/dev/null; then
  mise install erlang@27.2 elixir@1.18.4-otp-27
  eval "$(mise activate bash)"
fi

##
## 3. Force Hex into OFFLINE mode
##    We rely on deps/ + mix.lock being committed already.
##
echo "🌐 [Step 3] Forcing Hex into offline mode..."
export HEX_OFFLINE=1

# DO NOT delete mix.lock
# DO NOT set HEX_MIRROR or HEX_UNSAFE_HTTPS here.

##
## 4. Ensure Rebar3 via GitHub (works through proxy)
##
echo "📦 [Step 4] Ensuring Rebar3..."
REBAR3_PATH="$HOME/.mix/rebar3"
mkdir -p "$(dirname "$REBAR3_PATH")"

if [ ! -x "$REBAR3_PATH" ]; then
  curl -fSL \
    https://github.com/erlang/rebar3/releases/latest/download/rebar3 \
    -o "$REBAR3_PATH"
  chmod +x "$REBAR3_PATH"
fi

export MIX_REBAR3="$REBAR3_PATH"

##
## 5. Dependencies: verify only, do NOT fetch from the network.
##    deps/ must already be present from the repo.
##
echo "📥 [Step 5] Verifying dependencies (offline)..."

# This should NOT hit the network because HEX_OFFLINE=1.
# If deps/ is missing, this will fail and tell you.
mix deps.get || {
  echo "❌ mix deps.get failed in offline mode."
  echo "   Make sure deps/ and mix.lock are committed from a machine with working Hex."
  exit 1
}

##
## 6. Tailwind: download binary from GitHub (proxy allows this).
##
echo "🎨 [Step 6] Manually installing Tailwind..."
TAILWIND_VERSION=3.4.3

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64|amd64) ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l) ARCH="armv7" ;;
esac

TARGET="${OS}-${ARCH}"
if [ "$OS" = "linux" ] && command -v ldd >/dev/null && ldd --version 2>&1 | grep -qi musl; then
  TARGET="${TARGET}-musl"
fi

TAILWIND_DEST="_build/tailwind-${TARGET}"
mkdir -p "$(dirname "$TAILWIND_DEST")"

curl -fSL \
  "https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}/tailwindcss-${TARGET}" \
  -o "$TAILWIND_DEST"

chmod +x "$TAILWIND_DEST"

##
## 7. Compile project
##
echo "⚙️  [Step 7] Compiling project..."
mix deps.compile
mix compile

echo "✅ Setup Complete (offline Hex)."
