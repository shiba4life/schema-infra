#!/usr/bin/env bash
# Unit test: the schema canary has a required default alarm set and fails
# closed when an alarm is ALARM, missing, or unreadable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export LASTGIT_DEPLOY_LOG_DIR="$TMP/state"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin"

cat >"$TMP/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
name=""
echo "$@" >>"${MOCK_AWS_LOG:-/dev/null}"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--alarm-names" ]; then name="${2:-}"; break; fi
  shift
done
case "${MOCK_ALARM_MODE:-ok}:$name" in
  alarm:schema-mutation-gate-internal-error-prod) echo ALARM ;;
  missing:schema-mutation-gate-hourly-quota-prod) echo None ;;
  *) echo OK ;;
esac
AWS
chmod +x "$TMP/bin/aws"

# shellcheck source=/dev/null
source "$ROOT/scripts/deploy/canary-lib.sh"
unset SCHEMA_CANARY_ALARM_NAMES || true

export MOCK_AWS_LOG="$TMP/aws-default.log"
: >"$MOCK_AWS_LOG"
MOCK_ALARM_MODE=ok canary_alarms_ok us-east-1
grep -q 'schema-mutation-gate-hourly-quota-prod' "$MOCK_AWS_LOG" || {
  echo "unset SCHEMA_CANARY_ALARM_NAMES did not query hourly-quota alarm" >&2
  cat "$MOCK_AWS_LOG" >&2
  exit 1
}
grep -q 'schema-mutation-gate-internal-error-prod' "$MOCK_AWS_LOG" || {
  echo "unset SCHEMA_CANARY_ALARM_NAMES did not query internal-error alarm" >&2
  cat "$MOCK_AWS_LOG" >&2
  exit 1
}

export MOCK_AWS_LOG="$TMP/aws-empty.log"
: >"$MOCK_AWS_LOG"
SCHEMA_CANARY_ALARM_NAMES="" MOCK_ALARM_MODE=ok canary_alarms_ok us-east-1
grep -q 'schema-mutation-gate-hourly-quota-prod' "$MOCK_AWS_LOG" || {
  echo "empty SCHEMA_CANARY_ALARM_NAMES degraded past the default alarm set" >&2
  cat "$MOCK_AWS_LOG" >&2
  exit 1
}

if grep -q 'soak gate is time-only' "$ROOT/scripts/deploy/canary-lib.sh"; then
  echo "canary-lib.sh still contains the time-only degrade path" >&2
  exit 1
fi

if MOCK_ALARM_MODE=alarm canary_alarms_ok us-east-1; then
  echo "expected ALARM to block promotion" >&2
  exit 1
fi
if MOCK_ALARM_MODE=missing canary_alarms_ok us-east-1; then
  echo "expected a missing required alarm to block promotion" >&2
  exit 1
fi

export SCHEMA_CANARY_ALARM_NAMES="custom-schema-alarm"
MOCK_ALARM_MODE=ok canary_alarms_ok us-east-1
echo "ok canary-alarm-gate $(basename "$ROOT")"
