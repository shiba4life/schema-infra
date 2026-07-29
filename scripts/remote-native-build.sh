#!/usr/bin/env bash
#
# Build the schema Lambda on a native x86_64 Linux builder over SSH.
#
# Deploy-path decision decision-schema-infra-deploy-path-native-x86-pc
# (2026-07-28): QEMU emulation of the amazonlinux:2023 build on Apple
# Silicon repeatedly wedged mid-compile (cfg-if, 0% CPU, no rustc child,
# unaffected by CARGO_BUILD_JOBS=1) and stalled the single deploy lane for
# hours. The same container image runs natively on the PC runner (WSL2
# Ubuntu 24.04, x86_64 Docker), where parallel Cargo is safe and a
# persistent cache makes warm builds fast.
#
# Contract: identical inputs and identical container to the local path in
# build.sh — only the execution host differs. The artifact lands at
#   <fold>/target/lambda/server_lambda/bootstrap.zip
# exactly as the local path produces it, and its SHA-256 is verified
# against the remote digest before this script succeeds.
#
# Security boundary: AWS credentials never leave the Mac. The Forgejo
# token used for the fold fetch travels only inside the stdin-fed driver
# script and GIT_CONFIG_* environment variables on the PC — never on the
# PC's disk or command lines. GH_PAT (private cargo git deps) is passed to
# docker via a mode-0600 env-file that is deleted in the driver's exit
# trap.
#
# Usage (called by build.sh; requires SCHEMA_BUILD_REMOTE_HOST):
#   scripts/remote-native-build.sh <fold-pin-oid> <local-fold-dir>
#
# Env:
#   SCHEMA_BUILD_REMOTE_HOST        ssh host alias (e.g. "pc") — required
#   SCHEMA_BUILD_REMOTE_WSL_DISTRO  default Ubuntu-24.04
#   SCHEMA_BUILD_REMOTE_WSL_USER    default tom
#   SCHEMA_BUILD_REMOTE_ROOT       default /home/tom/schema-lambda-build
#   SCHEMA_BUILD_REMOTE_JOBS        default 16 (native: parallel is safe)
#   SCHEMA_BUILD_REMOTE_FOLD_URL    default http://100.109.94.59:3300/EdgeVector/fold.git
#   SCHEMA_BUILD_REMOTE_TIMEOUT_S   default 5400 (bounds the container build)
#   BUILD_PROFILE                   release | dev-release (default release)
#   FORGE_TOKEN                     Forgejo token; falls back to the
#                                   keychain item "forgejo-token"
#   GH_PAT                          optional, for private cargo git deps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FOLD_PIN="${1:?usage: remote-native-build.sh <fold-pin-oid> <local-fold-dir>}"
LOCAL_FOLD_DIR="${2:?usage: remote-native-build.sh <fold-pin-oid> <local-fold-dir>}"

REMOTE_HOST="${SCHEMA_BUILD_REMOTE_HOST:?SCHEMA_BUILD_REMOTE_HOST is required}"
WSL_DISTRO="${SCHEMA_BUILD_REMOTE_WSL_DISTRO:-Ubuntu-24.04}"
WSL_USER="${SCHEMA_BUILD_REMOTE_WSL_USER:-tom}"
REMOTE_ROOT="${SCHEMA_BUILD_REMOTE_ROOT:-/home/tom/schema-lambda-build}"
REMOTE_JOBS="${SCHEMA_BUILD_REMOTE_JOBS:-16}"
FOLD_URL="${SCHEMA_BUILD_REMOTE_FOLD_URL:-http://100.109.94.59:3300/EdgeVector/fold.git}"
BUILD_TIMEOUT_S="${SCHEMA_BUILD_REMOTE_TIMEOUT_S:-5400}"
PROFILE="${BUILD_PROFILE:-release}"

FORGE_TOKEN_VALUE="${FORGE_TOKEN:-}"
if [ -z "$FORGE_TOKEN_VALUE" ] && command -v security >/dev/null 2>&1; then
    FORGE_TOKEN_VALUE="$(security find-generic-password -s forgejo-token -w 2>/dev/null || true)"
fi
if [ -z "$FORGE_TOKEN_VALUE" ]; then
    echo "FAIL: no Forgejo token (set FORGE_TOKEN or keychain item forgejo-token)" >&2
    exit 1
fi

# WSL one-shot commands go through Windows OpenSSH + cmd.exe, which eats
# pipes and complex quoting in the REMOTE COMMAND LINE. Rule: remote
# command lines stay trivially simple; all real logic travels via
# `bash -s` over stdin, where normal bash semantics apply.
rwsl() {
    ssh -o ConnectTimeout=15 "$REMOTE_HOST" "wsl -d $WSL_DISTRO -u $WSL_USER -- $*"
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/schema-remote-build.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "== remote native build: host=$REMOTE_HOST fold_pin=$FOLD_PIN profile=$PROFILE jobs=$REMOTE_JOBS =="

# ---------------------------------------------------------------
# 1. Ship the schema-infra tree (scripts + build recipe only; fold
#    arrives via git on the builder, caches live remotely).
# ---------------------------------------------------------------
TREE_TAR="$TMP_DIR/schema-infra-tree.tar.gz"
tar -czf "$TREE_TAR" -C "$SCRIPT_DIR" \
    --exclude ./.git \
    --exclude ./fold \
    --exclude ./.docker-cache \
    --exclude ./target \
    --exclude ./cdk/node_modules \
    .
rwsl mkdir -p "$REMOTE_ROOT/incoming" "$REMOTE_ROOT/tree"
ssh -o ConnectTimeout=15 "$REMOTE_HOST" \
    "wsl -d $WSL_DISTRO -u $WSL_USER -- tar -xzf - -C $REMOTE_ROOT/incoming" \
    < "$TREE_TAR"

# ---------------------------------------------------------------
# 2. Driver: refresh tree, fetch fold at the pin, run the SAME
#    amazonlinux:2023 container build natively.
# ---------------------------------------------------------------
DRIVER="$TMP_DIR/driver.sh"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf 'ROOT=%q\n' "$REMOTE_ROOT"
    printf 'PIN=%q\n' "$FOLD_PIN"
    printf 'FOLD_URL=%q\n' "$FOLD_URL"
    printf 'PROFILE=%q\n' "$PROFILE"
    printf 'JOBS=%q\n' "$REMOTE_JOBS"
    printf 'BUILD_TIMEOUT_S=%q\n' "$BUILD_TIMEOUT_S"
    printf 'FORGE_TOKEN=%q\n' "$FORGE_TOKEN_VALUE"
    printf 'GH_PAT=%q\n' "${GH_PAT:-}"
    cat <<'DRIVER_BODY'
ENV_FILE=""
cleanup() { [ -n "$ENV_FILE" ] && rm -f "$ENV_FILE"; }
trap cleanup EXIT

# Refresh the build tree from incoming; caches and the fold clone persist.
rsync -a --delete \
    --exclude /.docker-cache/ \
    --exclude /fold/ \
    --exclude /target/ \
    "$ROOT/incoming"/ "$ROOT/tree"/

# fold mirror + checkout at the pinned submodule OID. The token rides in
# GIT_CONFIG_* env vars only (not argv, not on disk).
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.$FOLD_URL.extraHeader"
export GIT_CONFIG_VALUE_0="Authorization: token $FORGE_TOKEN"
if [ ! -d "$ROOT/fold-mirror.git" ]; then
    git init --bare -q "$ROOT/fold-mirror.git"
fi
if ! git -C "$ROOT/fold-mirror.git" cat-file -e "$PIN^{commit}" 2>/dev/null; then
    git -C "$ROOT/fold-mirror.git" fetch -q "$FOLD_URL" '+refs/heads/*:refs/heads/*'
fi
git -C "$ROOT/fold-mirror.git" cat-file -e "$PIN^{commit}" || {
    echo "FAIL: fold pin $PIN not reachable from forge heads" >&2
    exit 1
}
if [ ! -d "$ROOT/tree/fold/.git" ]; then
    git clone -q --shared --no-checkout "$ROOT/fold-mirror.git" "$ROOT/tree/fold"
fi
git -C "$ROOT/tree/fold" fetch -q origin
git -C "$ROOT/tree/fold" checkout -qf "$PIN"
git -C "$ROOT/tree/fold" clean -fdxq -e target
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

mkdir -p "$ROOT/tree/.docker-cache/cargo" "$ROOT/tree/.docker-cache/rustup" \
         "$ROOT/tree/.docker-cache/cargo-target"

ENV_FILE="$(mktemp "$ROOT/.build-env.XXXXXX")"
chmod 600 "$ENV_FILE"
{
    echo "BUILD_PROFILE=$PROFILE"
    echo "CARGO_BUILD_JOBS=$JOBS"
    echo "CARGO_HOME=/build/schema-infra/.docker-cache/cargo"
    echo "RUSTUP_HOME=/build/schema-infra/.docker-cache/rustup"
    echo "CARGO_TARGET_DIR=/build/schema-infra/.docker-cache/cargo-target"
    [ -n "$GH_PAT" ] && echo "GH_PAT=$GH_PAT"
} > "$ENV_FILE"

echo "== container build (native x86_64, jobs=$JOBS, timeout=${BUILD_TIMEOUT_S}s) =="
timeout "$BUILD_TIMEOUT_S" docker run --rm \
    --platform linux/amd64 \
    -v "$ROOT/tree":/build/schema-infra \
    -w /build/schema-infra/fold \
    --env-file "$ENV_FILE" \
    amazonlinux:2023 \
    bash /build/schema-infra/scripts/lambda-container-build.sh

ZIP="$ROOT/tree/fold/target/lambda/server_lambda/bootstrap.zip"
[ -f "$ZIP" ] || { echo "FAIL: build produced no $ZIP" >&2; exit 1; }
echo "REMOTE_ZIP_SHA256=$(sha256sum "$ZIP" | awk '{print $1}')"
DRIVER_BODY
} > "$DRIVER"

ssh -o ConnectTimeout=15 "$REMOTE_HOST" \
    "wsl -d $WSL_DISTRO -u $WSL_USER -- bash -s" \
    < "$DRIVER" | tee "$TMP_DIR/driver.log"

REMOTE_SHA="$(grep -o 'REMOTE_ZIP_SHA256=[0-9a-f]*' "$TMP_DIR/driver.log" | tail -1 | cut -d= -f2)"
if [ -z "$REMOTE_SHA" ]; then
    echo "FAIL: remote build did not report an artifact digest" >&2
    exit 1
fi

# ---------------------------------------------------------------
# 3. Retrieve the artifact and verify the digest locally.
# ---------------------------------------------------------------
B64="$TMP_DIR/bootstrap.zip.b64"
rwsl base64 -w0 "$REMOTE_ROOT/tree/fold/target/lambda/server_lambda/bootstrap.zip" > "$B64"
DEST_DIR="$LOCAL_FOLD_DIR/target/lambda/server_lambda"
mkdir -p "$DEST_DIR"
base64 --decode < "$B64" > "$DEST_DIR/bootstrap.zip"

LOCAL_SHA="$(shasum -a 256 "$DEST_DIR/bootstrap.zip" | awk '{print $1}')"
if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
    echo "FAIL: artifact digest mismatch (remote=$REMOTE_SHA local=$LOCAL_SHA)" >&2
    exit 1
fi
echo "== remote native build OK: sha256=$LOCAL_SHA =="
