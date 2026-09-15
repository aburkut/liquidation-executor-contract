#!/usr/bin/env python3
"""Compare a contract's storage layout with its committed snapshot.

    forge inspect <C> storageLayout --json | layout_compare.py <snapshot> <C> [--write|--exact]

Default mode is append-only: every snapshot entry must still be at the same
index with the same slot, offset, label and type; new entries may follow.
`--exact` also refuses appended entries (a Genesis must equal its
implementation). `--write` replaces the snapshot with the current layout.

An executor behind a proxy keeps its storage across implementations, so a
moved or retyped variable silently reads another variable's bytes. This check
is the only thing standing between an upgrade and that.
"""
import json
import sys


def normalise(raw: str) -> list:
    data = json.loads(raw)
    types = data.get("types") or {}
    return [
        {
            "slot": str(entry["slot"]),
            "offset": int(entry["offset"]),
            "label": entry["label"],
            "type": types.get(entry["type"], {}).get("label", entry["type"]),
        }
        for entry in data["storage"]
    ]


def main() -> int:
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        print(__doc__)
        return 2
    snapshot_path, name = args
    current = normalise(sys.stdin.read())

    if "--write" in flags:
        with open(snapshot_path, "w") as f:
            json.dump(current, f, indent=2)
            f.write("\n")
        print(f"wrote {snapshot_path}: {len(current)} entries from {name}")
        return 0

    with open(snapshot_path) as f:
        snapshot = json.load(f)

    bad = False
    for i, want in enumerate(snapshot):
        got = current[i] if i < len(current) else None
        if got != want:
            print(f"!! {name}: entry {i} was {want}, now {got}")
            bad = True
    extra = current[len(snapshot):]
    if "--exact" in flags and extra:
        print(f"!! {name}: {len(extra)} entries beyond {snapshot_path}: {extra}")
        bad = True
    if bad:
        return 1
    note = f", {len(extra)} appended" if extra else ""
    print(f"ok {name}: {len(snapshot)} entries match {snapshot_path}{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
