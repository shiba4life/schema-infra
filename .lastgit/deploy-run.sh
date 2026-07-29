#!/usr/bin/env bash
# Supervise LastGit deploy-pipeline for schema-infra.
set -euo pipefail
REPO="${1:-schema-infra}"
CONTEXT="${LASTGIT_DEPLOY_CONTEXT:-deploy-pipeline}"
REF="${LASTGIT_DEPLOY_REF:-refs/heads/main}"
# The staged deploy performs a dev build/deploy, smoke test, prod build/deploy,
# prod smoke, and canary pin. Cold Docker/Rust/CDK runs can exceed three hours.
DEFAULT_TIMEOUT_MS=21600000
TIMEOUT_MS="${LASTGIT_DEPLOY_TIMEOUT_MS:-$DEFAULT_TIMEOUT_MS}"
# Production LastGit now lives on the primary Mini socket. Launchd jobs do not
# always inherit the interactive shell discovery env, so pin it here instead of
# falling back to the retired TCP/code-node route.
export LASTGIT_SOCKET="${LASTGIT_SOCKET:-$HOME/.lastdb/data/folddb.sock}"
export LASTGIT_SCHEMA_MAP="${LASTGIT_SCHEMA_MAP:-$HOME/.lastgit/schema-map.json}"
# Deploy-path decision decision-schema-infra-deploy-path-native-x86-pc:
# the Lambda build runs on the native x86_64 builder by default. Set
# SCHEMA_BUILD_REMOTE_HOST="" to force the legacy local QEMU path.
export SCHEMA_BUILD_REMOTE_HOST="${SCHEMA_BUILD_REMOTE_HOST-pc}"
# docker + cargo tooling must be on PATH for launchd (minimal default PATH).
# Prefer the installed LastGit CLI so deploy status writes use the same
# HashRange-compatible client path as the primary forge supervisor.
LASTGIT_INSTALL_BIN_DIR="${LASTGIT_INSTALL_BIN_DIR:-$HOME/.local/bin}"
export PATH="${LASTGIT_INSTALL_BIN_DIR}:${HOME}/.cargo/bin:${HOME}/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
command -v lastgit >/dev/null || {
  echo "FAIL: installed lastgit missing on PATH; expected ${LASTGIT_INSTALL_BIN_DIR}/lastgit" >&2
  exit 1
}
LOG_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-$REPO}"
mkdir -p "$LOG_DIR"
RUNNER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER_HEAD="$(git -C "$RUNNER_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "deploy-run: repo=$REPO context=$CONTEXT ref=$REF timeout_ms=$TIMEOUT_MS logs=$LOG_DIR runner_root=$RUNNER_ROOT runner_head=$RUNNER_HEAD"
WATCH_PID=""
CARGO_GUARD_PID=""

# Older accepted schema-infra commits predate the repository-level
# CARGO_BUILD_JOBS=1 mitigation. They still have to pass their original staged
# deploy, but parallel rustc spawning under Docker Desktop's x86 QEMU can
# deadlock before the fixed commit reaches the head of this serialized queue.
# Install the equivalent Cargo setting in each ephemeral scratch CARGO_HOME.
# This changes build scheduling only; it does not modify the checked-out source
# or bypass any deploy/smoke/canary stage. Existing Cargo config is preserved.
install_legacy_cargo_guard() {
  local scratch cargo_home tmp
  shopt -s nullglob
  for scratch in "$LOG_DIR"/scratch/schema-infra-*; do
    cargo_home="$scratch/.docker-cache/cargo"
    mkdir -p "$cargo_home"
    if [ ! -e "$cargo_home/config.toml" ]; then
      tmp="$cargo_home/config.toml.tmp.$$"
      printf '[build]\njobs = 1\n' >"$tmp"
      mv "$tmp" "$cargo_home/config.toml"
    fi
  done
}
start_cargo_guard() {
  (
    while true; do
      install_legacy_cargo_guard
      sleep 1
    done
  ) &
  CARGO_GUARD_PID=$!
}
stop() {
  [ -n "$WATCH_PID" ] && kill "$WATCH_PID" 2>/dev/null || true
  [ -n "$CARGO_GUARD_PID" ] && kill "$CARGO_GUARD_PID" 2>/dev/null || true
}
trap 'stop; exit 0' INT TERM
start_watch() {
  lastgit ci watch --repo "$REPO" --context "$CONTEXT" --ref "$REF" \
    --timeout-ms "$TIMEOUT_MS" --max-concurrency 1 \
    --state-file "$LOG_DIR/deploy.cursor" --scratch-dir "$LOG_DIR/scratch" \
    >>"$LOG_DIR/deploy.log" 2>&1 &
  WATCH_PID=$!
  echo "pid=$WATCH_PID"
}
install_legacy_cargo_guard
start_cargo_guard
start_watch
while true; do
  watch_status=0
  wait "$WATCH_PID" || watch_status=$?
  echo "deploy-run: watch pid=$WATCH_PID exited status=$watch_status; restarting"
  start_watch
done
