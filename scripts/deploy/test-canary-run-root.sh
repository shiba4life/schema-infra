#!/usr/bin/env bash
# Unit test: canary run-root refresh refuses dirty/stale clones and fast-forwards
# a clean behind checkout. Also checks the launchd installer writes a durable
# wrapper + --refresh-run-root ProgramArguments.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/deploy/canary-run-root.sh"
INSTALLER="$ROOT/.lastgit/install-canary-ticker-launchd.sh"
test -f "$HELPER" || { echo "missing $HELPER" >&2; exit 1; }
test -x "$INSTALLER" || { echo "missing $INSTALLER" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git_init_ident() {
  git -C "$1" config user.email "canary-test@example.com"
  git -C "$1" config user.name "Canary Test"
}

make_upstream() {
  local bare="$TMP/upstream.git"
  local seed="$TMP/seed"
  git init -b main --bare "$bare" >/dev/null 2>&1 || git init --bare "$bare" >/dev/null
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/main >/dev/null
  git init -b main "$seed" >/dev/null 2>&1 || git init "$seed" >/dev/null
  git_init_ident "$seed"
  git -C "$seed" checkout -B main >/dev/null 2>&1 || git -C "$seed" checkout -b main >/dev/null
  mkdir -p "$seed/.lastgit" "$seed/scripts/deploy"
  printf '#!/usr/bin/env bash\necho ticker-v1\n' >"$seed/.lastgit/canary-ticker.sh"
  chmod +x "$seed/.lastgit/canary-ticker.sh"
  echo '# lib v1' >"$seed/scripts/deploy/canary-lib.sh"
  echo 'v1' >"$seed/README"
  git -C "$seed" add -A
  git -C "$seed" commit -m "v1" >/dev/null
  git -C "$seed" remote add origin "$bare"
  git -C "$seed" push -u origin main >/dev/null
  printf '%s\n' "$bare"
}

clone_at() {
  local dest="$1"
  git clone -q -b main "$UPSTREAM" "$dest"
  git_init_ident "$dest"
}

advance_upstream() {
  local work="$TMP/upstream-work"
  rm -rf "$work"
  git clone -q -b main "$UPSTREAM" "$work"
  git_init_ident "$work"
  echo 'v2' >"$work/README"
  printf '#!/usr/bin/env bash\necho ticker-v2\n' >"$work/.lastgit/canary-ticker.sh"
  git -C "$work" add -A
  git -C "$work" commit -m "v2" >/dev/null
  git -C "$work" push origin main >/dev/null
}

# shellcheck source=/dev/null
source "$HELPER"

UPSTREAM="$(make_upstream)"
CLONE="$TMP/clone"
clone_at "$CLONE"

# Fresh clone matching origin/main succeeds.
canary_refresh_run_root "$CLONE"

# Dirty tree refuses.
echo dirty >"$CLONE/README"
if canary_refresh_run_root "$CLONE" 2>"$TMP/dirty.err"; then
  echo "expected dirty run-root to fail" >&2
  exit 1
fi
grep -q 'dirty' "$TMP/dirty.err" || { echo "dirty failure did not name dirty tree:" >&2; cat "$TMP/dirty.err" >&2; exit 1; }
git -C "$CLONE" checkout -- README

# Pin to stale commit (skip fetch so origin/main stays at v2 while HEAD is v1).
advance_upstream
OLD="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" fetch -q origin
NEW="$(git -C "$CLONE" rev-parse origin/main)"
if [ "$OLD" = "$NEW" ]; then
  echo "expected upstream to advance" >&2
  exit 1
fi
git -C "$CLONE" checkout -q "$OLD"
export CANARY_SKIP_FETCH=1
if canary_assert_run_root_fresh "$CLONE" 2>"$TMP/stale.err"; then
  echo "expected pinned stale HEAD to fail assert" >&2
  exit 1
fi
grep -q 'stale' "$TMP/stale.err" || { echo "stale failure did not name stale:" >&2; cat "$TMP/stale.err" >&2; exit 1; }
unset CANARY_SKIP_FETCH

# Refresh fast-forwards the clean behind clone.
git -C "$CLONE" checkout -q main
canary_refresh_run_root "$CLONE"
HAVE="$(git -C "$CLONE" rev-parse HEAD)"
if [ "$HAVE" != "$NEW" ]; then
  echo "expected refresh to fast-forward to $NEW, got $HAVE" >&2
  exit 1
fi

# Installer writes durable wrapper + refresh ProgramArguments (no live launchctl).
export LASTGIT_DEPLOY_LOG_DIR="$TMP/log"
export LASTGIT_DEPLOY_PLIST="$TMP/com.edgevector.lastgit-canary-ticker-schema-infra.plist"
export LASTGIT_CANARY_REPO_ROOT="$CLONE"
export LASTGIT_CANARY_SKIP_LAUNCHCTL=1
"$INSTALLER" install >/dev/null
test -x "$TMP/log/canary-ticker-wrapper.sh"
test -f "$TMP/log/canary-run-root.sh"
plutil -p "$LASTGIT_DEPLOY_PLIST" >"$TMP/plist.txt"
grep -q 'canary-ticker-wrapper.sh' "$TMP/plist.txt" || {
  echo "plist missing durable wrapper path:" >&2
  cat "$TMP/plist.txt" >&2
  exit 1
}
grep -q 'refresh-run-root' "$TMP/plist.txt" || {
  echo "plist missing refresh step:" >&2
  cat "$TMP/plist.txt" >&2
  exit 1
}
if grep -q 'mirror-clones/schema-infra/.lastgit/canary-ticker.sh' "$TMP/plist.txt"; then
  echo "plist still points launchd at the unmanaged clone ticker" >&2
  cat "$TMP/plist.txt" >&2
  exit 1
fi

echo "ok canary-run-root $(basename "$ROOT")"
