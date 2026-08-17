#!/usr/bin/env bash
# Drive the shipped input-digest function: same inputs → same digest,
# any hashed recipe file change → new digest.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIGEST="$ROOT/scripts/deploy/artifact-digest.sh"
ENSURE="$ROOT/scripts/deploy/ensure-artifact.sh"
test -f "$DIGEST" || { echo "missing $DIGEST" >&2; exit 1; }
test -f "$ENSURE" || { echo "missing $ENSURE" >&2; exit 1; }

# shellcheck source=artifact-digest.sh
source "$DIGEST"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/artifact-digest-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Minimal tree with the files the digest actually hashes.
mkdir -p "$TMP/repo/scripts"
cp "$ROOT/scripts/lambda-container-build.sh" "$TMP/repo/scripts/"
cp "$ROOT/scripts/remote-native-build.sh" "$TMP/repo/scripts/"
cp "$ROOT/scripts/lambda-container-build-lib.sh" "$TMP/repo/scripts/"
cp "$ROOT/scripts/ensure-builder-image.sh" "$TMP/repo/scripts/"

pin="c19f4d52a2eafc110fe988716100d27ad423eb04"
a="$(schema_infra_input_digest "$TMP/repo" "$pin" release)"
b="$(schema_infra_input_digest "$TMP/repo" "$pin" release)"
[ "$a" = "$b" ] || { echo "FAIL: digest not stable" >&2; exit 1; }
[ "${#a}" -eq 64 ] || { echo "FAIL: digest not sha256 ($a)" >&2; exit 1; }
echo "ok digest stable $a"

# fold pin change
c="$(schema_infra_input_digest "$TMP/repo" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" release)"
[ "$a" != "$c" ] || { echo "FAIL: fold pin should change digest" >&2; exit 1; }
echo "ok digest changes with fold pin"

# profile change
d="$(schema_infra_input_digest "$TMP/repo" "$pin" dev-release)"
[ "$a" != "$d" ] || { echo "FAIL: profile should change digest" >&2; exit 1; }
echo "ok digest changes with profile"

# each hashed recipe file
for f in lambda-container-build.sh remote-native-build.sh lambda-container-build-lib.sh ensure-builder-image.sh; do
    echo "# digest-probe $f" >> "$TMP/repo/scripts/$f"
    got="$(schema_infra_input_digest "$TMP/repo" "$pin" release)"
    [ "$got" != "$a" ] || { echo "FAIL: changing $f should change digest" >&2; exit 1; }
    # restore so the next file is the only delta
    # (copy from original)
    cp "$ROOT/scripts/$f" "$TMP/repo/scripts/$f"
    rest="$(schema_infra_input_digest "$TMP/repo" "$pin" release)"
    [ "$rest" = "$a" ] || { echo "FAIL: restoring $f did not restore digest" >&2; exit 1; }
    echo "ok digest changes with $f"
done

# ensure-artifact.sh actually calls the shipped digest function
grep -q 'source "$SCRIPT_DIR/scripts/deploy/artifact-digest.sh"' "$ENSURE"
grep -q 'schema_infra_input_digest' "$ENSURE"
echo "ok ensure-artifact uses shipped digest"

echo "ok artifact-digest tests"
