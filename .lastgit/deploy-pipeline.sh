#!/usr/bin/env bash
# Staged deploy pipeline for schema-infra (LastGit context: deploy-pipeline).
#
# Three release planes (design-schema-lambda-fast-deployment §3):
#   code-only        fold pin changed, CDK inputs did not → publish the
#                    prebuilt digest-verified artifact via AWS CLI (no CDK,
#                    no compile in the release path).
#   infrastructure   CDK/config/layer/deploy-machinery changed → CDK deploy
#                    referencing the prebuilt artifact (never compiles Rust
#                    inside the CDK path).
#   no-impact        docs/tests/proofs/frontend only → skip with an explicit
#                    successful reason.
#
# Both deploying planes: DEV (us-west-2) → dev smoke → PROD (us-east-1) with
# ~10% weighted canary on the `live` alias → prod smoke → soak state
# (canary-ticker promotes after CANARY_SOAK_HOURS if alarms stay non-ALARM).
#
# Env:
#   DEPLOY_FREEZE=true           skip all
#   LASTGIT_DEPLOY_SKIP_PROD=1   stop after successful dev smoke
#   CANARY_SOAK_HOURS=24         canary soak duration
#   CANARY_WEIGHT=0.1            fraction of prod traffic on new version
#   SCHEMA_CANARY_ALARM_NAMES    optional override; defaults to the required
#                                production mutation-gate alarm set
#   SCHEMA_DEPLOY_FORCE_KIND     override the classifier (code-only|
#                                infrastructure|no-impact) for drills
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/deploy/canary-lib.sh
source "$(pwd)/scripts/deploy/canary-lib.sh"
# shellcheck source=scripts/deploy/telemetry.sh
source "$(pwd)/scripts/deploy/telemetry.sh"

OID="${LASTGIT_CI_OID:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
echo "== [schema staged-deploy] oid=$OID =="
schema_telemetry_emit pipeline_start "oid=$OID" "telemetry_file=$(schema_telemetry_file)"

if [ "${DEPLOY_FREEZE:-}" = "true" ]; then
  echo "DEPLOY_FREEZE=true — skip"
  exit 0
fi

command -v aws >/dev/null || { echo "FAIL: aws missing" >&2; exit 1; }
command -v curl >/dev/null || { echo "FAIL: curl missing" >&2; exit 1; }
aws sts get-caller-identity --query Account --output text >/dev/null
echo "AWS identity OK"

# ---------- 0a. Coalesce to the newest eligible tip ----------
# Design §4: pending main events coalesce to the newest deploy-relevant tip
# before expensive work; obsolete intermediate tips must not each consume the
# serialized lane. This check runs BEFORE any build or AWS mutation, so it can
# never interrupt a prod alias change. Fail-open: if the tip cannot be
# resolved (node busy), deploy this event normally.
if [ "${SCHEMA_DEPLOY_SKIP_COALESCE:-}" != "1" ]; then
  TIP_OID=""
  if timeout 120 git fetch -q origin refs/heads/main 2>/dev/null; then
    TIP_OID="$(git rev-parse FETCH_HEAD 2>/dev/null || true)"
  fi
  if [ -n "$TIP_OID" ] && [ "$TIP_OID" != "$OID" ] && \
     git merge-base --is-ancestor "$OID" "$TIP_OID" 2>/dev/null; then
    schema_telemetry_emit release_row "oid=$OID" "kind=superseded" \
      "skipped_deploy=true" "superseded_by=$TIP_OID"
    echo "lastgit schema deploy-pipeline PASSED (superseded by newest tip $TIP_OID — coalesced)"
    exit 0
  fi
fi

# ---------- 0. Classify the change ----------
LAST_OID_FILE="${STATE_DIR}/last-deployed-oid"
BASE_OID=""
[ -f "$LAST_OID_FILE" ] && BASE_OID="$(head -1 "$LAST_OID_FILE" | tr -d '[:space:]')"

if [ -n "${SCHEMA_DEPLOY_FORCE_KIND:-}" ]; then
  KIND="$SCHEMA_DEPLOY_FORCE_KIND"
  KIND_REASON="forced via SCHEMA_DEPLOY_FORCE_KIND"
elif [ -z "$BASE_OID" ]; then
  KIND="infrastructure"
  KIND_REASON="no last-deployed state — conservative full path"
else
  CLASSIFY="$(bash scripts/deploy/classify-change.sh "$BASE_OID" "$OID" .)"
  KIND="${CLASSIFY%%$'\t'*}"
  KIND_REASON="${CLASSIFY#*$'\t'}"
fi
echo "== classification: $KIND ($KIND_REASON) base=${BASE_OID:-none} =="
schema_telemetry_emit classification \
  "kind=$KIND" "reason=$KIND_REASON" "base_oid=${BASE_OID:-}" "head_oid=$OID"

if [ "$KIND" = "no-impact" ]; then
  schema_telemetry_emit release_row "oid=$OID" "kind=no-impact" \
    "skipped_deploy=true" "reason=$KIND_REASON"
  echo "lastgit schema deploy-pipeline PASSED (no deploy impact: $KIND_REASON)"
  exit 0
fi

# ---------- 0b. Ensure the artifact (build plane; once per input digest) ----------
if [ "$KIND" = "infrastructure" ] && [ -f .gitmodules ] && [ "${LASTGIT_DEPLOY_SKIP_SUBMODULE:-}" != "1" ]; then
  # Only the CDK path needs the fold submodule (Code.fromAsset + layer
  # inputs). Code-only releases read the pin from the gitlink and consume
  # the cached/remote-built artifact directly.
  git submodule update --init --recursive
fi

ENSURE_OUT="$(bash scripts/deploy/ensure-artifact.sh)"
MANIFEST="$(printf '%s\n' "$ENSURE_OUT" | grep '^MANIFEST=' | cut -d= -f2-)"
ARTIFACT_CACHE="$(printf '%s\n' "$ENSURE_OUT" | grep '^CACHE=' | cut -d= -f2)"
[ -s "$MANIFEST" ] || { echo "FAIL: ensure-artifact produced no manifest" >&2; exit 1; }
ARTIFACT_READY_EPOCH="$(schema_telemetry_epoch)"
echo "== artifact manifest: $MANIFEST (cache=$ARTIFACT_CACHE) =="

DEV_NEW_VER=""
DEV_CODE_SHA=""
PROD_NEW_VER=""
PROD_CODE_SHA=""
OLD_VER=""

if [ "$KIND" = "code-only" ]; then
  # ---------- CODE-ONLY: publish, never CDK ----------
  echo "== STAGE 1: code-publish DEV =="
  stage_started="$(schema_telemetry_stage_start dev_deploy)"
  DEV_OUT="$(bash scripts/deploy/code-publish.sh dev us-west-2 "$MANIFEST")"
  schema_telemetry_stage_end dev_deploy "$stage_started"
  DEV_NEW_VER="$(printf '%s\n' "$DEV_OUT" | grep '^NEW_VERSION=' | cut -d= -f2)"
  DEV_CODE_SHA="$(printf '%s\n' "$DEV_OUT" | grep '^CODE_SHA256=' | cut -d= -f2-)"
  DEV_LIVE_EPOCH="$(schema_telemetry_epoch)"

  echo "== STAGE 2: smoke DEV =="
  stage_started="$(schema_telemetry_stage_start dev_smoke)"
  bash ./scripts/deploy/smoke-dev.sh
  schema_telemetry_stage_end dev_smoke "$stage_started"

  if [ "${LASTGIT_DEPLOY_SKIP_PROD:-}" = "1" ] || [ "${LASTGIT_DEPLOY_SKIP_PROD:-}" = "true" ]; then
    echo "LASTGIT_DEPLOY_SKIP_PROD — stop after dev smoke"
    echo "lastgit schema deploy-pipeline PASSED (dev only)"
    exit 0
  fi

  echo "== STAGE 3: code-publish PROD + canary pin =="
  export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1
  FN=$(schema_fn_name prod us-east-1 || true)
  OLD_VER=""
  if [ -n "${FN:-}" ] && [ "$FN" != "None" ]; then
    OLD_VER=$(alias_version "$FN" us-east-1 || true)
    canary_log "pre-prod alias version old=${OLD_VER:-none} fn=$FN"
  fi
  stage_started="$(schema_telemetry_stage_start prod_deploy_code_publish)"
  PROD_OUT="$(bash scripts/deploy/code-publish.sh prod us-east-1 "$MANIFEST")"
  schema_telemetry_stage_end prod_deploy_code_publish "$stage_started"
  PROD_NEW_VER="$(printf '%s\n' "$PROD_OUT" | grep '^NEW_VERSION=' | cut -d= -f2)"
  PROD_CODE_SHA="$(printf '%s\n' "$PROD_OUT" | grep '^CODE_SHA256=' | cut -d= -f2-)"
  PROD_CANARY_EPOCH="$(schema_telemetry_epoch)"
  CDK_INVOKED=false
  NEW_VER="$PROD_NEW_VER"
else
  # ---------- INFRASTRUCTURE: CDK with the prebuilt artifact ----------
  # CDK reads two assets: the extracted Lambda zip (materialized by
  # ensure-artifact) and the fastembed model Layer. A fresh scratch has no
  # layer yet — materialize it before --skip-build (release #2's failure).
  bash scripts/deploy/ensure-layer.sh
  echo "== STAGE 1: deploy DEV (CDK, prebuilt artifact) =="
  export AWS_REGION=us-west-2 AWS_DEFAULT_REGION=us-west-2
  stage_started="$(schema_telemetry_stage_start dev_deploy)"
  ./deploy.sh dev --yes --skip-build
  schema_telemetry_stage_end dev_deploy "$stage_started"
  DEV_LIVE_EPOCH="$(schema_telemetry_epoch)"
  DEV_FN=$(schema_fn_name dev us-west-2 || true)
  if [ -n "${DEV_FN:-}" ] && [ "$DEV_FN" != "None" ]; then
    DEV_CODE_SHA="$(aws lambda get-function-configuration --function-name "$DEV_FN" \
      --region us-west-2 --query 'CodeSha256' --output text 2>/dev/null || true)"
  fi

  echo "== STAGE 2: smoke DEV =="
  stage_started="$(schema_telemetry_stage_start dev_smoke)"
  bash ./scripts/deploy/smoke-dev.sh
  schema_telemetry_stage_end dev_smoke "$stage_started"

  if [ "${LASTGIT_DEPLOY_SKIP_PROD:-}" = "1" ] || [ "${LASTGIT_DEPLOY_SKIP_PROD:-}" = "true" ]; then
    echo "LASTGIT_DEPLOY_SKIP_PROD — stop after dev smoke"
    echo "lastgit schema deploy-pipeline PASSED (dev only)"
    exit 0
  fi

  echo "== STAGE 3: deploy PROD + canary pin =="
  export AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1
  FN=$(schema_fn_name prod us-east-1 || true)
  OLD_VER=""
  if [ -n "${FN:-}" ] && [ "$FN" != "None" ]; then
    OLD_VER=$(alias_version "$FN" us-east-1 || true)
    canary_log "pre-prod alias version old=${OLD_VER:-none} fn=$FN"
  fi
  stage_started="$(schema_telemetry_stage_start prod_deploy_skip_build)"
  ./deploy.sh prod --yes --skip-build
  schema_telemetry_stage_end prod_deploy_skip_build "$stage_started"
  PROD_CANARY_EPOCH="$(schema_telemetry_epoch)"
  CDK_INVOKED=true
fi

echo "== STAGE 4: smoke PROD =="
stage_started="$(schema_telemetry_stage_start prod_smoke)"
bash ./scripts/deploy/smoke-dev.sh prod
schema_telemetry_stage_end prod_smoke "$stage_started"

FN=$(schema_fn_name prod us-east-1)
if [ "$KIND" = "code-only" ]; then
  NEW_VER="$PROD_NEW_VER"
else
  NEW_VER=$(alias_version "$FN" us-east-1)
  PROD_CODE_SHA="$(aws lambda get-function-configuration --function-name "$FN" \
    --qualifier "$NEW_VER" --region us-east-1 --query 'CodeSha256' --output text 2>/dev/null || true)"
  # CDK path: canary pin happens here (code-only pinned inside code-publish).
  canary_log "post-prod alias version new=$NEW_VER fn=$FN"
  stage_started="$(schema_telemetry_stage_start canary_pin)"
  set_canary_weights "$FN" us-east-1 "${OLD_VER:-}" "$NEW_VER" || true
  schema_telemetry_stage_end canary_pin "$stage_started"
fi

# ---------- 5. Soak state + release evidence ----------
STARTED=$(canary_ts)
export CANARY_SOAK_HOURS="${CANARY_SOAK_HOURS:-24}"
PROMOTE_AFTER=$(python3 - <<PY
from datetime import datetime, timedelta, timezone
import os
h = float(os.environ.get("CANARY_SOAK_HOURS", "24"))
print((datetime.now(timezone.utc) + timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)
if [ -n "${OLD_VER:-}" ] && [ "$OLD_VER" != "$NEW_VER" ] && [ "$OLD_VER" != '$LATEST' ] && [ "$OLD_VER" != "None" ]; then
  write_canary_state "$OID" "${OLD_VER:-}" "$NEW_VER" "$FN" "us-east-1" "$STARTED" "$PROMOTE_AFTER"
  canary_log "canary soak until $PROMOTE_AFTER (CANARY_SOAK_HOURS=${CANARY_SOAK_HOURS})"
  SOAK_MSG="prod canary soaking until $PROMOTE_AFTER"
else
  clear_canary_state 2>/dev/null || rm -f "${STATE_FILE:-}"
  canary_log "canary: no weighted pin (old==new or missing) — no soak state"
  SOAK_MSG="prod deploy; no canary pin needed"
fi

schema_telemetry_emit release_row \
  "oid=$OID" \
  "kind=$KIND" \
  "cache=$ARTIFACT_CACHE" \
  "manifest=$MANIFEST" \
  "dev_code_sha256=${DEV_CODE_SHA:-}" \
  "prod_code_sha256=${PROD_CODE_SHA:-}" \
  "dev_version=${DEV_NEW_VER:-}" \
  "prod_version=${NEW_VER:-}" \
  "dev_live_epoch=${DEV_LIVE_EPOCH:-}" \
  "prod_canary_epoch=${PROD_CANARY_EPOCH:-}" \
  "artifact_ready_epoch=${ARTIFACT_READY_EPOCH:-}" \
  "cdk_invoked=$CDK_INVOKED" \
  "rust_compiled=false" \
  "builds_for_digest=1"

printf '%s\n' "$OID" > "$LAST_OID_FILE"
echo "lastgit schema deploy-pipeline PASSED ($SOAK_MSG)"
if [ "$KIND" != "code-only" ]; then
  echo "Promote via: .lastgit/canary-ticker.sh (launchd) or manual scripts/deploy promote"
fi
