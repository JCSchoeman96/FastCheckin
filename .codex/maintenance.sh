#!/bin/bash
# Codex Cloud maintenance script
# This runs after setup.sh to clean up and finalize the environment

set +e  # Don't fail on errors in maintenance

echo "🧹 [Codex] Running maintenance tasks..."

# Clean up temporary files
rm -f /tmp/*.ez 2>/dev/null || true
rm -f /tmp/erl_ssl.conf 2>/dev/null || true

# Clear build artifacts if needed
rm -rf _build/dev/lib/*/.compile.app_ebin 2>/dev/null || true

# Verify setup completed
if [[ -f "mix.exs" ]]; then
  echo "✓ Project ready"
else
  echo "⚠ No mix.exs found"
fi

echo "✅ Maintenance complete"
