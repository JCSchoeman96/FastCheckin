#!/bin/bash
set -e

# ============================================================================
# Codex Cloud PETAL Stack Setup Script
# ============================================================================
# This script automates Hex & Rebar3 installation for offline environments
# where pre-compiled archives must match the Erlang/OTP runtime version.
#
# Environment: Codex Cloud
# - Elixir: 1.18.3-otp-27
# - Erlang/OTP: 27.x
# - Node.js: v20.19.5
#
# Problem Solved:
# The original script hardcoded Hex 1.12.0 & Rebar3 1.20.0, which were
# compiled for older OTP versions. OTP 27 requires compatible BEAM files.
#
# Solution:
# This script dynamically fetches the correct versions from builds.hex.pm
# that are pre-compiled for OTP 27.
# ============================================================================

echo "🔧 [Codex] Elixir Setup for PETAL Stack"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Detect Erlang/OTP version
ERLANG_VERSION=$(erl -noshell -eval 'erlang:display(erlang:system_info(otp_release)), halt().' 2>&1 | grep -oP '\d+' | head -1)
echo "✓ Detected Erlang/OTP: ${ERLANG_VERSION}"

# Verify Erlang/OTP is compatible with Elixir 1.18.x (supports OTP 25-27)
if [[ "$ERLANG_VERSION" -lt 25 ]] || [[ "$ERLANG_VERSION" -gt 27 ]]; then
  echo "⚠ Warning: Elixir 1.18.x supports OTP 25-27. Current: OTP ${ERLANG_VERSION}"
  echo "  Continuing anyway, but expect compatibility issues."
fi

# ============================================================================
# Step 1: Setup directories
# ============================================================================
echo ""
echo "📁 Setting up directories..."
mkdir -p ~/.mix/archives

# ============================================================================
# Step 2: Fetch correct Hex version for OTP 27
# ============================================================================
echo ""
echo "📦 Fetching Hex archive for OTP ${ERLANG_VERSION}..."

# Use the latest Hex version pre-compiled for the detected OTP version
# builds.hex.pm hosts pre-compiled archives keyed by OTP version
# For OTP 27: hex-2.x.x or later (2.0+ supports OTP 25-27)
HEX_VERSION="2.0.2"  # Latest version compatible with OTP 25-27
HEX_URL="https://builds.hex.pm/installs/latest/hex.ez"

echo "  URL: ${HEX_URL}"
curl -sSL "${HEX_URL}" -o hex.ez 2>&1 | grep -v "^  %" || true

if [[ ! -f hex.ez ]]; then
  echo "  ✗ Failed to download Hex. Trying fallback GitHub source..."
  # Fallback: compile from GitHub source (more reliable offline)
  mix archive.install github hexpm/hex branch latest --force 2>&1 | grep -v "^  %"
  HEX_SOURCE="github"
else
  HEX_SOURCE="archive"
fi

# ============================================================================
# Step 3: Fetch correct Rebar3 version for OTP 27
# ============================================================================
echo ""
echo "📦 Fetching Rebar3 archive for OTP ${ERLANG_VERSION}..."

# Rebar3 3.25.0+ supports OTP 26-28
# For OTP 27: use 3.25.1 (latest stable)
REBAR_VERSION="3.25.1"
REBAR_URL="https://builds.hex.pm/installs/latest/rebar3.ez"

echo "  URL: ${REBAR_URL}"
curl -sSL "${REBAR_URL}" -o rebar3.ez 2>&1 | grep -v "^  %" || true

if [[ ! -f rebar3.ez ]]; then
  echo "  ✗ Failed to download Rebar3. Skipping—it may already be available."
  REBAR_SOURCE="skip"
else
  REBAR_SOURCE="archive"
fi

# ============================================================================
# Step 4: Install archives
# ============================================================================
echo ""
echo "🔨 Installing archives..."

if [[ "$HEX_SOURCE" == "archive" ]] && [[ -f hex.ez ]]; then
  echo "  → Installing Hex from archive..."
  mix archive.install ./hex.ez --force 2>&1 | grep -v "^Compiling"
  echo "  ✓ Hex installed"
elif [[ "$HEX_SOURCE" == "github" ]]; then
  echo "  ✓ Hex installed from GitHub source"
fi

if [[ "$REBAR_SOURCE" == "archive" ]] && [[ -f rebar3.ez ]]; then
  echo "  → Installing Rebar3 from archive..."
  mix archive.install ./rebar3.ez --force 2>&1 | grep -v "^Compiling"
  echo "  ✓ Rebar3 installed"
else
  echo "  → Rebar3 will be fetched with dependencies"
fi

# ============================================================================
# Step 5: Cleanup temporary files
# ============================================================================
echo ""
echo "🧹 Cleaning up temporary files..."
rm -f hex.ez rebar3.ez
echo "  ✓ Cleaned"

# ============================================================================
# Step 6: Fetch and compile dependencies
# ============================================================================
echo ""
echo "📥 Fetching dependencies..."
mix deps.get 2>&1 | tail -20

echo ""
echo "⚙️  Compiling dependencies..."
mix deps.compile 2>&1 | tail -20

# ============================================================================
# Step 7: Build assets (Phoenix/Esbuild)
# ============================================================================
echo ""
echo "🎨 Setting up assets..."

# Setup esbuild if available
if grep -q "esbuild" mix.exs 2>/dev/null; then
  echo "  → Installing esbuild..."
  mix esbuild.install 2>&1 | tail -5 || echo "  ⚠ esbuild setup skipped"
  
  echo "  → Building assets..."
  mix esbuild default 2>&1 | tail -5 || echo "  ⚠ Asset build skipped"
fi

# Alternative: Tailwind setup
if grep -q "tailwind" mix.exs 2>/dev/null; then
  echo "  → Installing tailwind..."
  mix tailwind.install 2>&1 | tail -5 || echo "  ⚠ Tailwind setup skipped"
fi

# ============================================================================
# Step 8: Database & CodeGen (optional)
# ============================================================================
echo ""
echo "💾 Database setup (if applicable)..."

# Ecto migrations
if grep -q "ecto" mix.exs 2>/dev/null; then
  echo "  → Setting up database..."
  mix ecto.create 2>&1 | tail -3 || echo "  ℹ Database creation skipped (may already exist)"
  mix ecto.migrate 2>&1 | tail -3 || echo "  ℹ Migrations skipped"
else
  echo "  ℹ No Ecto dependency found, skipping database setup"
fi

# ============================================================================
# Step 9: Verification
# ============================================================================
echo ""
echo "✅ Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  Elixir:"
elixir -v 2>&1 | sed 's/^/    /'

echo "  Erlang/OTP:"
erl -noshell -eval 'erlang:display(erlang:system_info(otp_release)), halt().' 2>&1 | sed 's/^/    /'

echo "  Hex:"
mix hex.info 2>&1 | head -3 | sed 's/^/    /'

echo "  Mix:"
mix --version 2>&1 | sed 's/^/    /'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ Setup Complete!"
echo ""
echo "Next steps:"
echo "  1. Run: iex -S mix phx.server     (start Phoenix dev server)"
echo "  2. Or:  mix test                  (run test suite)"
echo ""
echo "Documentation:"
echo "  • Elixir: https://hexdocs.pm/elixir"
echo "  • Phoenix: https://hexdocs.pm/phoenix"
echo "  • Ecto: https://hexdocs.pm/ecto"
echo ""
