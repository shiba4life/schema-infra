#!/usr/bin/env bash
# Install launchd agent that runs canary-ticker every 15 minutes.
#
# Launchd points at a durable wrapper under LASTGIT_DEPLOY_LOG_DIR. That
# wrapper refreshes ~/.lastgit/mirror-clones/schema-infra to canonical main
# and refuses dirty/stale trees before exec'ing the clone's ticker. Do not
# point launchd at the clone path itself — nothing kept that checkout in
# sync (papercut-schema-infra-canary-ticker-stale-mirror-clone-time-only-gate).
set -euo pipefail

REPO_SLUG="schema-infra"
LABEL="com.edgevector.lastgit-canary-ticker-${REPO_SLUG}"
LOG_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-${REPO_SLUG}}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DEFAULT_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
PLIST="${LASTGIT_DEPLOY_PLIST:-$DEFAULT_PLIST}"
DOMAIN="gui/$(id -u)"
CMD="${1:-install}"
INSTALLER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_SRC="${INSTALLER_ROOT}/scripts/deploy/canary-run-root.sh"
WRAPPER="${LOG_DIR}/canary-ticker-wrapper.sh"
HELPER_DST="${LOG_DIR}/canary-run-root.sh"

mkdir -p "$LOG_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR" 2>/dev/null || true

if [ -z "${LASTGIT_DEPLOY_PLIST:-}" ] && { [ ! -d "$LAUNCH_AGENTS_DIR" ] || [ ! -w "$LAUNCH_AGENTS_DIR" ]; }; then
  PLIST="${LOG_DIR}/${LABEL}.plist"
fi
mkdir -p "$(dirname "$PLIST")"

resolve_repo_root() {
  local c
  for c in \
    "${LASTGIT_CANARY_REPO_ROOT:-}" \
    "$HOME/.lastgit/mirror-clones/${REPO_SLUG}" \
    "$INSTALLER_ROOT" \
    "$HOME/code/edgevector/${REPO_SLUG}"
  do
    [ -n "${c:-}" ] || continue
    if [ -x "$c/.lastgit/canary-ticker.sh" ] && [ -f "$c/scripts/deploy/canary-lib.sh" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

write_durable_wrapper() {
  local repo_root="$1"
  if [ ! -f "$HELPER_SRC" ]; then
    echo "FAIL: missing $HELPER_SRC" >&2
    return 1
  fi
  cp -f "$HELPER_SRC" "$HELPER_DST"
  cat > "$WRAPPER" <<WRAP
#!/usr/bin/env bash
# Durable canary ticker entrypoint. Refresh the run-root, then exec the
# clone's ticker. --refresh-run-root is accepted so launchd ProgramArguments
# names the refresh step.
set -euo pipefail
case "\${1:-}" in
  --refresh-run-root) shift ;;
esac
export HOME="\${HOME:-$HOME}"
export PATH="\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LASTGIT_SOCKET="\${LASTGIT_SOCKET:-\$HOME/.lastdb/data/folddb.sock}"
export LASTGIT_SCHEMA_MAP="\${LASTGIT_SCHEMA_MAP:-\$HOME/.lastgit/schema-map.json}"
export LASTGIT_DEPLOY_LOG_DIR="\${LASTGIT_DEPLOY_LOG_DIR:-$LOG_DIR}"
export LASTGIT_CANARY_REPO_ROOT="\${LASTGIT_CANARY_REPO_ROOT:-$repo_root}"
export AWS_PROFILE="\${AWS_PROFILE:-default}"
HELPER="\${LASTGIT_DEPLOY_LOG_DIR}/canary-run-root.sh"
if [ ! -f "\$HELPER" ]; then
  echo "FAIL: missing durable helper \$HELPER" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "\$HELPER"
canary_refresh_run_root "\$LASTGIT_CANARY_REPO_ROOT"
export CANARY_RUN_ROOT_REFRESHED=1
exec /bin/bash "\$LASTGIT_CANARY_REPO_ROOT/.lastgit/canary-ticker.sh"
WRAP
  chmod +x "$WRAPPER" "$HELPER_DST"
}

REPO_ROOT="$(resolve_repo_root)" || {
  echo "FAIL: no durable ${REPO_SLUG} root with .lastgit/canary-ticker.sh + scripts/deploy/canary-lib.sh" >&2
  echo "  tried LASTGIT_CANARY_REPO_ROOT, ~/.lastgit/mirror-clones/${REPO_SLUG}, installer parent, ~/code/edgevector/${REPO_SLUG}" >&2
  exit 1
}

case "$CMD" in
  install)
    write_durable_wrapper "$REPO_ROOT"
    # shellcheck source=/dev/null
    source "$HELPER_DST"
    canary_refresh_run_root "$REPO_ROOT"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WRAPPER}</string>
    <string>--refresh-run-root</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>LASTGIT_DEPLOY_LOG_DIR</key><string>${LOG_DIR}</string>
    <key>LASTGIT_CANARY_REPO_ROOT</key><string>${REPO_ROOT}</string>
    <key>LASTGIT_SOCKET</key><string>${HOME}/.lastdb/data/folddb.sock</string>
    <key>LASTGIT_SCHEMA_MAP</key><string>${HOME}/.lastgit/schema-map.json</string>
    <key>AWS_PROFILE</key><string>default</string>
  </dict>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/canary-ticker.launchd.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/canary-ticker.launchd.log</string>
</dict>
</plist>
EOF

    if [ "${LASTGIT_CANARY_SKIP_LAUNCHCTL:-}" != "1" ]; then
      launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
      launchctl bootstrap "$DOMAIN" "$PLIST"
      launchctl enable "${DOMAIN}/${LABEL}" 2>/dev/null || true
      launchctl kickstart -k "${DOMAIN}/${LABEL}" 2>/dev/null || true
    fi

    echo "installed $LABEL -> $PLIST"
    echo "  wrapper=$WRAPPER"
    echo "  refresh=--refresh-run-root"
    echo "  repo_root=$REPO_ROOT"
    echo "  log_dir=$LOG_DIR"
    ;;
  uninstall)
    if [ "${LASTGIT_CANARY_SKIP_LAUNCHCTL:-}" != "1" ]; then
      launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    fi
    rm -f "$PLIST"
    echo "unloaded ${LABEL}"
    ;;
  status)
    echo "expected wrapper: ${WRAPPER}"
    echo "expected repo_root: ${REPO_ROOT}"
    echo "expected log_dir: ${LOG_DIR}"
    if [ -f "$PLIST" ]; then
      echo "installed plist:"
      plutil -p "$PLIST" 2>/dev/null | sed -n '1,120p' || true
    fi
    echo "launchd state:"
    launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | sed -n '1,80p' || echo "not loaded"
    echo "recent canary state log:"
    tail -20 "$LOG_DIR/canary.log" 2>/dev/null || true
    echo "recent canary launchd log:"
    tail -20 "$LOG_DIR/canary-ticker.launchd.log" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 install|uninstall|status" >&2
    exit 2
    ;;
esac
