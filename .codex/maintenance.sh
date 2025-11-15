#!/bin/bash

set -e

echo "🔄 [Codex Maintenance] Checking for updated deps..."

mix deps.get
mix deps.compile

echo "🎨 [Codex Maintenance] Rebuilding assets if needed..."
mix assets.build

echo "✅ [Codex Maintenance] Maintenance done."
