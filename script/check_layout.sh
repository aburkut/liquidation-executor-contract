#!/usr/bin/env bash
# Storage-layout guard for the upgradeable executors (see layout_compare.py).
#
#   script/check_layout.sh           check against layout/*.json (CI)
#   script/check_layout.sh --write   regenerate the snapshots — a reviewed commit
#
# Expects a prior `forge build` (CI runs it first); `forge inspect` reuses the cache.
set -euo pipefail
cd "$(dirname "$0")/.."

layout() {
  forge inspect "$1" storageLayout --json 2>/dev/null
}

if [ "${1:-}" = "--write" ]; then
  layout ArbExecutor | python3 script/layout_compare.py layout/ArbExecutor.json ArbExecutor --write
  layout LiquidationExecutor | python3 script/layout_compare.py layout/LiquidationExecutor.json LiquidationExecutor --write
  exit 0
fi

status=0
layout ArbExecutor | python3 script/layout_compare.py layout/ArbExecutor.json ArbExecutor || status=1
layout LiquidationExecutor | python3 script/layout_compare.py layout/LiquidationExecutor.json LiquidationExecutor || status=1
exit $status
