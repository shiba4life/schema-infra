#!/usr/bin/env bash
# Install the durable LastGit deploy-pipeline supervisor for schema-infra.
set -euo pipefail

REPO_SLUG="schema-infra"
LABEL="com.edgevector.lastgit-deploy-${REPO_SLUG}"
LOG_DIR="${LASTGIT_DEPLOY_LOG_DIR:-$HOME/.lastgit/deploy-${REPO_SLUG}}"
RUNNER="${LOG_DIR}/deploy-run.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${ROOT}/.lastgit/deploy-run.sh"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DEFAULT_PLIST="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"
PLIST="${LASTGIT_DEPLOY_PLIST:-$DEFAULT_PLIST}"
DOMAIN="gui/$(id -u)"
CMD="${1:-install}"

[ -x "$SOURCE" ] || {
  echo "FAIL: deploy runner is not executable: $SOURCE" >&2
  exit 1
}

mkdir -p "$LOG_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR" 2>/dev/null || true

if [ -z "${LASTGIT_DEPLOY_PLIST:-}" ] && { [ ! -d "$LAUNCH_AGENTS_DIR" ] || [ ! -w "$LAUNCH_AGENTS_DIR" ]; }; then
  PLIST="${LOG_DIR}/${LABEL}.plist"
fi
mkdir -p "$(dirname "$PLIST")"

case "$CMD" in
  install)
    cp -f "$SOURCE" "$RUNNER"
    chmod +x "$RUNNER"

    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUNNER}</string>
    <string>${REPO_SLUG}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>${HOME}/.local/bin:${HOME}/.cargo/bin:${HOME}/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>LASTGIT_SOCKET</key><string>${HOME}/.lastdb/data/folddb.sock</string>
    <key>LASTGIT_SCHEMA_MAP</key><string>${HOME}/.lastgit/schema-map.json</string>
    <key>LASTGIT_DEPLOY_CONTEXT</key><string>deploy-pipeline</string>
    <key>LASTGIT_DEPLOY_LOG_DIR</key><string>${LOG_DIR}</string>
    <key>AWS_PROFILE</key><string>${AWS_PROFILE:-default}</string>
    <key>SCHEMA_BUILD_REMOTE_HOST</key><string>${SCHEMA_BUILD_REMOTE_HOST:-pc}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>${LOG_DIR}/launchd.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/launchd.log</string>
</dict>
</plist>
EOF

    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl enable "${DOMAIN}/${LABEL}" 2>/dev/null || true
    launchctl kickstart -k "${DOMAIN}/${LABEL}" 2>/dev/null || true

    echo "installed ${LABEL} -> ${RUNNER}"
    echo "  plist=${PLIST}"
    echo "  log_dir=${LOG_DIR}"
    ;;
  uninstall)
    launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST"
    echo "unloaded ${LABEL}"
    ;;
  status)
    echo "expected deploy runner: ${RUNNER}"
    echo "expected lastgit socket: ${HOME}/.lastdb/data/folddb.sock"
    if [ -f "$PLIST" ]; then
      echo "installed plist:"
      plutil -p "$PLIST" 2>/dev/null | sed -n '1,100p' || true
    fi
    echo "launchd state:"
    launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | sed -n '1,80p' || echo "not loaded"
    echo "recent deploy log:"
    tail -20 "$LOG_DIR/deploy.log" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 install|uninstall|status" >&2
    exit 2
    ;;
esac
