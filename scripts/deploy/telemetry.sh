#!/usr/bin/env bash
# Secret-safe deploy telemetry helpers for schema-infra scripts.

schema_telemetry_epoch() {
  date -u +%s
}

schema_telemetry_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

schema_telemetry_json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n"))[1:-1])'
}

schema_telemetry_file() {
  # Watch-driven deploys run in ephemeral scratch checkouts; their telemetry
  # must outlive the checkout for the ten-release terminal-proof evidence.
  # Under a deploy runner (LASTGIT_DEPLOY_LOG_DIR set) default to a durable
  # per-OID file; local/manual runs keep the in-tree default.
  local file="${SCHEMA_DEPLOY_TELEMETRY_FILE:-}"
  if [ -z "$file" ]; then
    if [ -n "${LASTGIT_DEPLOY_LOG_DIR:-}" ]; then
      file="${LASTGIT_DEPLOY_LOG_DIR}/telemetry/${LASTGIT_CI_OID:-adhoc}.jsonl"
    else
      file="target/deploy-telemetry/schema-deploy-telemetry.jsonl"
    fi
  fi
  mkdir -p "$(dirname "$file")"
  printf '%s' "$file"
}

schema_telemetry_emit() {
  local event="$1"
  shift
  local ts file line json_pairs key value escaped
  ts="$(schema_telemetry_iso)"
  file="$(schema_telemetry_file)"
  line="SCHEMA_DEPLOY_TELEMETRY event=$event ts=$ts"
  json_pairs="\"event\":\"$event\",\"ts\":\"$ts\""
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    escaped="$(printf '%s' "$value" | schema_telemetry_json_escape)"
    line="$line $key=$value"
    json_pairs="$json_pairs,\"$key\":\"$escaped\""
  done
  printf '%s\n' "$line"
  printf '{%s}\n' "$json_pairs" >> "$file"
}

schema_telemetry_stage_start() {
  local stage="$1"
  local started
  started="$(schema_telemetry_epoch)"
  schema_telemetry_emit stage_start "stage=$stage" "started_epoch=$started" >&2
  printf '%s' "$started"
}

schema_telemetry_stage_end() {
  local stage="$1" started="$2"
  local ended duration
  ended="$(schema_telemetry_epoch)"
  duration=$(( ended - started ))
  schema_telemetry_emit stage_end "stage=$stage" "started_epoch=$started" "ended_epoch=$ended" "duration_sec=$duration"
}
