#!/usr/bin/env bash
# Measure the schema Lambda's dependency closure for the terminal-proof
# dependency budget: unique normal packages via cargo tree on the Lambda
# crate for the Linux target, plus presence checks for every banned needle
# prove.py enforces.
#
# Runs against the fold submodule of this checkout (the pinned sources that
# actually build the artifact). Writes dependency_budget_extra.json for
# collect.py into --aux-dir.
#
# Usage: count-packages.sh --aux-dir <dir>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AUX_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --aux-dir) AUX_DIR="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$AUX_DIR" ] || { echo "usage: count-packages.sh --aux-dir <dir>" >&2; exit 2; }
mkdir -p "$AUX_DIR"

FOLD="$SCRIPT_DIR/fold"
[ -f "$FOLD/Cargo.toml" ] || { echo "FAIL: fold submodule not initialized" >&2; exit 1; }

export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || { echo "FAIL: cargo missing" >&2; exit 1; }

TREE_FILE="$(mktemp "${TMPDIR:-/tmp}/lambda-tree.XXXXXX")"
trap 'rm -f "$TREE_FILE"' EXIT

# --prefix none --no-dedupe off: default dedupe fine; we only need the set
# of unique package names in the closure (normal deps; build/dev excluded).
cargo tree --locked --manifest-path "$FOLD/Cargo.toml" \
    -p schema_service_server_lambda --features fastembed \
    --target x86_64-unknown-linux-gnu \
    --edges normal --prefix none --format '{p}' \
    | awk '{print $1}' | sort -u > "$TREE_FILE"

COUNT="$(wc -l < "$TREE_FILE" | tr -d ' ')"

# The banned needle list is read from prove.py so the two can never drift.
python3 - "$SCRIPT_DIR" "$TREE_FILE" "$AUX_DIR" "$COUNT" <<'PY'
import json, re, sys
from pathlib import Path

root, tree_file, aux_dir, count = sys.argv[1:5]
prove = Path(root) / "scripts/proof/schema-lambda-fast-deployment/prove.py"
m = re.search(r"BANNED_PACKAGE_NEEDLES = \((.*?)\)", prove.read_text(), re.S)
if not m:
    sys.exit("cannot read BANNED_PACKAGE_NEEDLES from prove.py")
needles = re.findall(r'"([^"]+)"', m.group(1))

packages = set(Path(tree_file).read_text().split())
present = sorted(n for n in needles if n in packages)

out = {
    "normal_package_count": int(count),
    "banned_packages_present": present,
    "banned_packages_checked": needles,
}
Path(aux_dir, "dependency_budget_extra.json").write_text(
    json.dumps(out, indent=2) + "\n")
print(f"packages={count} banned_present={present or 'none'}")
PY
