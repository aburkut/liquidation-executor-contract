#!/usr/bin/env bash
# Fail the build while there is still room, not at deploy time.
#
# EIP-170 caps runtime bytecode at 24,576 bytes and `forge build --sizes`
# only complains once a contract is OVER it. LiquidationExecutor sits at
# 23,915 bytes after the 2026-09 gas work — 661 under — so the next handler
# added there could compile, pass every test and refuse to deploy. This
# check trips at THRESHOLD instead, on the PR.
#
# Usage: script/check_sizes.sh [threshold-bytes]   (default 24200)
set -euo pipefail
THRESHOLD="${1:-24200}"
forge build --sizes --json 2>/dev/null | python3 -c '
import json, sys
threshold = int(sys.argv[1])
sizes = json.load(sys.stdin)
bad = 0
for name in ("LiquidationExecutor", "ArbExecutor"):
    entry = sizes.get(name)
    if entry is None:
        print(f"!! {name}: not in the build output"); bad = 1; continue
    size = entry["runtime_size"]
    room = 24576 - size
    flag = "!!" if size > threshold else "ok"
    print(f"{flag} {name}: {size} bytes runtime, {room} under EIP-170, threshold {threshold}")
    if size > threshold:
        bad = 1
sys.exit(bad)
' "$THRESHOLD"
