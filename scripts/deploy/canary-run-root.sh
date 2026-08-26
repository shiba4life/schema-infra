#!/usr/bin/env bash
# Refresh + assert the schema-infra canary ticker run-root.
# Sourced by canary-ticker.sh and the durable launchd wrapper.
#
# Production promotion must not run July-vintage dirty clones. Fetch the
# canonical remote's main, fast-forward only, and fail closed on dirty or
# still-stale trees. lastgit is preferred; origin (GitHub mirror) is fallback.
set -euo pipefail

CANARY_RUN_ROOT_MAX_BEHIND="${CANARY_RUN_ROOT_MAX_BEHIND:-0}"

canary_run_root_log() {
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$line"
  if [ -n "${LASTGIT_DEPLOY_LOG_DIR:-}" ]; then
    mkdir -p "$LASTGIT_DEPLOY_LOG_DIR"
    echo "$line" >>"${LASTGIT_DEPLOY_LOG_DIR}/canary.log"
  fi
}

canary_run_root_remote() {
  local root="$1"
  if git -C "$root" remote get-url lastgit >/dev/null 2>&1; then
    printf '%s\n' lastgit
    return 0
  fi
  if git -C "$root" remote get-url origin >/dev/null 2>&1; then
    printf '%s\n' origin
    return 0
  fi
  echo "FAIL: canary run-root has no lastgit or origin remote: $root" >&2
  return 1
}

canary_run_root_fetch() {
  local root="$1" remote="$2"
  local spec="+refs/heads/main:refs/remotes/${remote}/main"
  if [ "${CANARY_SKIP_FETCH:-}" = "1" ]; then
    return 0
  fi
  GIT_TERMINAL_PROMPT=0 git -C "$root" fetch --quiet "$remote" "$spec"
}

canary_assert_run_root_fresh() {
  local root="${1:?canary_assert_run_root_fresh requires a checkout path}"
  local remote main_ref want have behind
  if [ ! -d "$root/.git" ] && [ ! -f "$root/.git" ]; then
    echo "FAIL: canary run-root is not a git checkout: $root" >&2
    return 1
  fi
  if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
    echo "FAIL: canary run-root is dirty; refuse to run local/stale code: $root" >&2
    git -C "$root" status -sb >&2
    return 1
  fi
  remote="$(canary_run_root_remote "$root")"
  main_ref="refs/remotes/${remote}/main"
  if ! git -C "$root" rev-parse --verify "$main_ref" >/dev/null 2>&1; then
    echo "FAIL: canary run-root missing ${remote}/main; fetch before promote: $root" >&2
    return 1
  fi
  want="$(git -C "$root" rev-parse "$main_ref")"
  have="$(git -C "$root" rev-parse HEAD)"
  behind="$(git -C "$root" rev-list --count HEAD.."${main_ref}")"
  if [ "$want" != "$have" ] || [ "$behind" -gt "$CANARY_RUN_ROOT_MAX_BEHIND" ]; then
    echo "FAIL: canary run-root is stale vs ${remote}/main (HEAD=$have ${remote}/main=$want behind=$behind max=$CANARY_RUN_ROOT_MAX_BEHIND)" >&2
    return 1
  fi
  return 0
}

canary_refresh_run_root() {
  local root="${1:?canary_refresh_run_root requires a checkout path}"
  local remote main_ref want have
  if [ ! -d "$root/.git" ] && [ ! -f "$root/.git" ]; then
    echo "FAIL: canary run-root is not a git checkout: $root" >&2
    return 1
  fi
  if [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]; then
    echo "FAIL: canary run-root is dirty; refuse to refresh or run: $root" >&2
    git -C "$root" status -sb >&2
    return 1
  fi
  remote="$(canary_run_root_remote "$root")"
  if ! canary_run_root_fetch "$root" "$remote"; then
    echo "FAIL: fetch ${remote}/main failed for canary run-root $root" >&2
    return 1
  fi
  main_ref="refs/remotes/${remote}/main"
  if ! git -C "$root" rev-parse --verify "$main_ref" >/dev/null 2>&1; then
    echo "FAIL: canary run-root has no ${remote}/main after fetch: $root" >&2
    return 1
  fi
  want="$(git -C "$root" rev-parse "$main_ref")"
  have="$(git -C "$root" rev-parse HEAD)"
  if [ "$want" != "$have" ]; then
    if git -C "$root" merge-base --is-ancestor "$have" "$want"; then
      git -C "$root" merge --ff-only --quiet "$main_ref"
    else
      echo "FAIL: canary run-root HEAD $have is not an ancestor of ${remote}/main $want" >&2
      return 1
    fi
  fi
  canary_assert_run_root_fresh "$root"
  have="$(git -C "$root" rev-parse HEAD)"
  canary_run_root_log "canary: run-root fresh HEAD=$have remote=$remote"
}
