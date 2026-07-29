#!/usr/bin/env bash
# Fixture tests for classify-change.sh — builds a throwaway git repo so the
# classifier is exercised against real diffs, no AWS and no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLASSIFY="$SCRIPT_DIR/classify-change.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/classify-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
git -C "$REPO" config commit.gpgsign false

commit_all() {
    git -C "$REPO" add -A >/dev/null
    git -C "$REPO" commit -qm "$1" >/dev/null
    git -C "$REPO" rev-parse HEAD
}

fake_gitlink() {
    # Record path `fold` as a gitlink (submodule pin) with the given OID.
    # The directory must exist in the worktree or a later `git add -A`
    # stages the gitlink as deleted (an uninitialized submodule is fine).
    mkdir -p "$REPO/fold"
    git -C "$REPO" update-index --add --cacheinfo "160000,$1,fold"
    git -C "$REPO" commit -qm "pin fold $1" >/dev/null
    git -C "$REPO" rev-parse HEAD
}

expect() {
    local label="$1" want="$2" base="$3" head="$4"
    local got
    got="$(bash "$CLASSIFY" "$base" "$head" "$REPO" | cut -f1)"
    if [ "$got" != "$want" ]; then
        echo "FAIL $label: want=$want got=$got" >&2
        exit 1
    fi
    echo "ok $label: $want"
}

# Base commit with representative files.
mkdir -p "$REPO/cdk/lib" "$REPO/docs" "$REPO/scripts/deploy" "$REPO/proofs" "$REPO/frontend"
echo base > "$REPO/cdk/lib/stack.ts"
echo base > "$REPO/docs/notes.md"
echo base > "$REPO/scripts/deploy/telemetry.sh"
echo base > "$REPO/frontend/index.html"
echo base > "$REPO/deploy.sh"
BASE="$(commit_all base)"
BASE="$(fake_gitlink 1111111111111111111111111111111111111111)"

# 1. fold pin bump only → code-only
C1="$(fake_gitlink 2222222222222222222222222222222222222222)"
expect "pin-bump" code-only "$BASE" "$C1"

# 2. docs only → no-impact
echo change > "$REPO/docs/notes.md"
C2="$(commit_all docs)"
expect "docs-only" no-impact "$C1" "$C2"

# 3. CDK change → infrastructure
echo change > "$REPO/cdk/lib/stack.ts"
C3="$(commit_all cdk)"
expect "cdk" infrastructure "$C2" "$C3"

# 4. mixed pin + CDK → infrastructure (conservative)
echo more > "$REPO/cdk/lib/stack.ts"
git -C "$REPO" add -A >/dev/null
git -C "$REPO" update-index --add --cacheinfo "160000,3333333333333333333333333333333333333333,fold"
git -C "$REPO" commit -qm mixed >/dev/null
C4="$(git -C "$REPO" rev-parse HEAD)"
expect "mixed" infrastructure "$C3" "$C4"

# 5. deploy machinery → infrastructure
echo change > "$REPO/scripts/deploy/telemetry.sh"
C5="$(commit_all machinery)"
expect "machinery" infrastructure "$C4" "$C5"

# 6. unmodeled path → infrastructure (conservative)
mkdir -p "$REPO/mystery"
echo new > "$REPO/mystery/file.bin"
C6="$(commit_all unmodeled)"
expect "unmodeled" infrastructure "$C5" "$C6"

# 7. frontend + proofs only → no-impact
echo change > "$REPO/frontend/index.html"
echo change > "$REPO/proofs/report.md"
C7="$(commit_all frontend-proofs)"
expect "frontend-proofs" no-impact "$C6" "$C7"

# 8. identical commits → no-impact
expect "empty-diff" no-impact "$C7" "$C7"

# 9. unknown base OID → infrastructure (conservative)
expect "unknown-base" infrastructure deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "$C7"

echo "ok classify-change tests"
