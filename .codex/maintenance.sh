#!/bin/bash
# .codex/maintenance.sh - Codex Cloud finalization script

set +e

echo "🧹 [Codex] Finalizing..."

# Clean temp files
rm -f /tmp/*.ez 2>/dev/null || true
rm -f /tmp/erl_ssl.conf 2>/dev/null || true

# Verify project exists
if [[ -f "mix.exs" ]]; then
  echo "✓ Project ready for development"
else
  echo "⚠ Warning: mix.exs not found"
fi

echo "✅ Done"
exit 0
