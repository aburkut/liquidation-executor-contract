#!/usr/bin/env bash
# Storage-layout guard for the upgradeable executors (see layout_compare.py).
#
#   script/check_layout.sh           check against layout/*.json (CI)
#   script/check_layout.sh --write   regenerate the snapshots — a reviewed commit
#
# Expects a prior `forge build` (CI runs it first); `forge inspect` reuses the cache.
set -euo pipefail
cd "$(dirname "$0")/.."

# layout <Contract>: its storage layout JSON on stdout. A failing
# `forge inspect` (unknown contract, stale build, compiler error) is reported
# with its stderr and a non-zero status instead of feeding the comparison an
# empty layout.
layout() {
  local out err
  err=$(mktemp)
  if ! out=$(forge inspect "$1" storageLayout --json 2>"$err"); then
    echo "!! forge inspect $1 failed:" >&2
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s\n' "$out"
}

# check <Contract> <snapshot> [flag]: compare with layout_compare.py; a failed
# `forge inspect` stops here rather than reaching the comparison.
check() {
  local json
  json=$(layout "$1") || return 1
  printf '%s\n' "$json" | python3 script/layout_compare.py "$2" "$1" ${3:+"$3"}
}

if [ "${1:-}" = "--write" ]; then
  check ArbExecutor layout/ArbExecutor.json --write
  check LiquidationExecutor layout/LiquidationExecutor.json --write
  exit 0
fi

status=0
check ArbExecutor layout/ArbExecutor.json || status=1
check LiquidationExecutor layout/LiquidationExecutor.json || status=1
# A Genesis writes the proxy's storage before the implementation reads it. Each
# Genesis is compared with the SAME committed snapshot its implementation is
# compared with (layout/<Executor>.json), in --exact mode: every snapshot entry
# at the same slot, offset, label and type, and no entries beyond the snapshot.
# The implementation is only held append-only against that snapshot.
check ArbExecutorGenesis layout/ArbExecutor.json --exact || status=1
check LiquidationExecutorGenesis layout/LiquidationExecutor.json --exact || status=1
exit $status
