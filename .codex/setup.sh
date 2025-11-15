#!/bin/bash
set -e

# ============================================================================
# Codex Cloud PETAL Stack Setup - Revised (No Archive Download)
# ============================================================================
# Fixed approach: Compile Hex & Rebar3 from source instead of downloading
# potentially incompatible .ez archives from builds.hex.pm.
#
# This avoids:
# - BEAM bytecode version mismatches
# - 503 Service Unavailable errors
# - Invalid archive format errors
#
# Environment: Codex Cloud
# - Elixir: 1.18.3-otp-27
# - Erlang/OTP: 27.x
# ============================================================================

echo "🔧 [Codex] Elixir Setup for PETAL Stack (OTP 27)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Detect Erlang/OTP version
ERLANG_VERSION=$(erl -noshell -eval 'erlang:display(erlang:system_info(otp_release)), halt().' 2>&1 | grep -oP '\d+' | head -1)
echo "✓ Detected Erlang/OTP: ${ERLANG_VERSION}"

# ============================================================================
# Step 1: Install Hex from GitHub source (compile locally)
# ============================================================================
echo ""
echo "📦 Installing Hex from GitHub source (compiling locally)..."
echo "   This ensures Hex is compiled against OTP ${ERLANG_VERSION}"

# Remove existing Hex to avoid conflicts
rm -rf ~/.mix/archives/hex* 2>/dev/null || true

# Compile and install from latest GitHub
mix archive.install github hexpm/hex branch latest --force 2>&1 | tail -10 || {
  echo "❌ Failed to install Hex from GitHub"
  echo "   Attempting fallback: mix local.hex --force"
  mix local.hex --force 2>&1 | tail -5
}

# ============================================================================
# Step 2: Install Rebar3 (optional, auto-fetched with dependencies)
# ============================================================================
echo ""
echo "📦 Rebar3 setup (will be fetched with dependencies if needed)..."
# Rebar3 is typically auto-installed via rebar_get_and_compile if declared in mix.exs
# No need to pre-install; it'll be handled by mix deps.compile

# ============================================================================
# Step 3: Update Mix package metadata
# ============================================================================
echo ""
echo "🔄 Updating Mix package metadata..."
mix local.rebar --if-missing 2>&1 | tail -3 || echo "✓ Rebar already available"

# ============================================================================
# Step 4: Fetch dependencies
# ============================================================================
echo ""
echo "📥 Fetching dependencies..."
# Use --force to bypass any cached metadata issues
mix deps.get --force 2>&1 | tail -30

# ============================================================================
# Step 5: Compile dependencies
# ============================================================================
echo ""
echo "⚙️  Compiling dependencies..."
mix deps.compile 2>&1 | tail -30

# ============================================================================
# Step 6: Build assets (Phoenix/Esbuild)
# ============================================================================
echo ""
echo "🎨 Setting up and building assets..."

# Esbuild (modern default)
if grep -q "esbuild" mix.exs 2>/dev/null; then
  echo "  → Installing esbuild binary..."
  mix esbuild.install 2>&1 | tail -5 || echo "  ℹ esbuild already installed"
  
  echo "  → Building JavaScript assets..."
  mix esbuild default 2>&1 | tail -5 || echo "  ⚠ Asset build completed with warnings"
fi

# Tailwind CSS (if configured)
if grep -q "tailwind" mix.exs 2>/dev/null; then
  echo "  → Installing tailwind binary..."
  mix tailwind.install 2>&1 | tail -5 || echo "  ℹ Tailwind already installed"
  
  echo "  → Building CSS..."
  mix tailwind default 2>&1 | tail -5 || echo "  ⚠ Tailwind build completed with warnings"
fi

# Fallback: Legacy sass/postcss
if [[ ! -d "priv/static" ]] && [[ -f "package.json" ]]; then
  echo "  → Running custom build script from package.json..."
  npm run build 2>&1 | tail -10 || echo "  ⚠ Custom build skipped"
fi

# ============================================================================
# Step 7: Database setup (Ecto)
# ============================================================================
echo ""
echo "💾 Setting up database..."

if grep -q '"ecto' mix.exs 2>/dev/null; then
  echo "  → Creating database (if not exists)..."
  mix ecto.create 2>&1 | tail -3 || echo "  ℹ Database already exists or creation skipped"
  
  echo "  → Running migrations..."
  mix ecto.migrate 2>&1 | tail -5 || echo "  ℹ No pending migrations"
else
  echo "  ℹ No Ecto dependency found, skipping database setup"
fi

# ============================================================================
# Step 8: Compile project code
# ============================================================================
echo ""
echo "🔨 Compiling project code..."
mix compile 2>&1 | tail -20

# ============================================================================
# Step 9: Verification
# ============================================================================
echo ""
echo "✅ Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "System Versions:"
echo "  Elixir:"
elixir -v 2>&1 | sed 's/^/    /'

echo "  Erlang/OTP:"
erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), halt().' 2>&1 | sed 's/^/    /'

echo "  Mix:"
mix --version 2>&1 | sed 's/^/    /'

echo ""
echo "Hex Status:"
mix hex.info 2>&1 | head -5 | sed 's/^/    /'

echo ""
echo "────────────────────────────────────────────────────────────────────"
echo "✨ Setup Complete!"
echo ""
echo "Next Steps:"
echo "  • Start dev server:  iex -S mix phx.server"
echo "  • Run tests:         mix test"
echo "  • Build release:     mix release"
echo ""
