#!/usr/bin/env bash
# Code-only release: publish a prebuilt, digest-verified Lambda artifact to
# one environment WITHOUT CDK and WITHOUT compiling anything
# (design-schema-lambda-fast-deployment §3, code-only path).
#
# Steps (all AWS CLI; CloudFormation remains the owner of function
# configuration — this path touches only published code versions and the
# `live` alias routing):
#   1. resolve the function name from the CloudFormation stack outputs;
#   2. update-function-code with the manifest's zip (direct upload);
#   3. wait, then verify the function's CodeSha256 equals the manifest's
#      artifact_code_sha256_b64 — STOP before any alias change on mismatch;
#   4. publish a version;
#   5. dev: point `live` at the new version (100%).
#      prod: keep `live` primary on the previous version and apply the
#      existing weighted canary pin (canary-lib.sh set_canary_weights).
#
# Usage:  code-publish.sh <env: dev|prod> <region> <manifest.json>
# Emits telemetry stages code_publish_<env>; prints "NEW_VERSION=<n>" and
# "CODE_SHA256=<b64>" for the caller's evidence row.
set -euo pipefail

ENV_NAME="${1:?usage: code-publish.sh <dev|prod> <region> <manifest.json>}"
REGION="${2:?usage: code-publish.sh <dev|prod> <region> <manifest.json>}"
MANIFEST="${3:?usage: code-publish.sh <dev|prod> <region> <manifest.json>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/deploy/telemetry.sh
source "$SCRIPT_DIR/scripts/deploy/telemetry.sh"
# shellcheck source=scripts/deploy/canary-lib.sh
source "$SCRIPT_DIR/scripts/deploy/canary-lib.sh"

export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"

manifest_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$MANIFEST" "$1"
}

ZIP_DIR="$(cd "$(dirname "$MANIFEST")" && pwd)"
ZIP="$ZIP_DIR/bootstrap.zip"
EXPECTED_B64="$(manifest_field artifact_code_sha256_b64)"
[ -s "$ZIP" ] || { echo "FAIL: no artifact zip next to manifest: $ZIP" >&2; exit 1; }

# Re-verify the artifact bytes against the manifest before shipping them.
ACTUAL_B64="$(openssl dgst -sha256 -binary "$ZIP" | base64)"
if [ "$ACTUAL_B64" != "$EXPECTED_B64" ]; then
    echo "FAIL: artifact bytes do not match manifest (want=$EXPECTED_B64 got=$ACTUAL_B64)" >&2
    exit 1
fi

FN="$(schema_fn_name "$ENV_NAME" "$REGION")"
if [ -z "$FN" ] || [ "$FN" = "None" ]; then
    echo "FAIL: cannot resolve function name for $ENV_NAME/$REGION" >&2
    exit 1
fi

stage_started="$(schema_telemetry_stage_start "code_publish_${ENV_NAME}")"

OLD_VER="$(alias_version "$FN" "$REGION" || true)"
canary_log "code-publish($ENV_NAME): fn=$FN pre-publish live=${OLD_VER:-none}"

aws lambda update-function-code \
    --function-name "$FN" \
    --zip-file "fileb://$ZIP" \
    --no-publish \
    --query 'CodeSha256' --output text >/dev/null
aws lambda wait function-updated-v2 --function-name "$FN" 2>/dev/null || \
    aws lambda wait function-updated --function-name "$FN"

GOT_SHA="$(aws lambda get-function-configuration --function-name "$FN" \
    --query 'CodeSha256' --output text)"
if [ "$GOT_SHA" != "$EXPECTED_B64" ]; then
    # Digest gate: never mutate alias routing onto unverified bytes.
    echo "FAIL: deployed CodeSha256 ($GOT_SHA) != manifest ($EXPECTED_B64) — alias untouched" >&2
    schema_telemetry_stage_end "code_publish_${ENV_NAME}" "$stage_started"
    exit 1
fi

NEW_VER="$(aws lambda publish-version --function-name "$FN" \
    --query 'Version' --output text)"
canary_log "code-publish($ENV_NAME): published version $NEW_VER code_sha=$GOT_SHA"

if [ "$ENV_NAME" = "dev" ]; then
    aws lambda update-alias --function-name "$FN" --name live \
        --function-version "$NEW_VER" \
        --routing-config '{}' >/dev/null
    canary_log "code-publish(dev): live → $NEW_VER (100%)"
else
    if ! set_canary_weights "$FN" "$REGION" "${OLD_VER:-}" "$NEW_VER"; then
        # No prior version to weight — put live fully on the new version,
        # same behavior as the CDK path's no-pin case.
        aws lambda update-alias --function-name "$FN" --name live \
            --function-version "$NEW_VER" \
            --routing-config '{}' >/dev/null
        canary_log "code-publish(prod): no weighted pin — live → $NEW_VER (100%)"
    fi
fi

schema_telemetry_stage_end "code_publish_${ENV_NAME}" "$stage_started"
schema_telemetry_emit code_publish \
    "env=$ENV_NAME" \
    "function=$FN" \
    "new_version=$NEW_VER" \
    "old_version=${OLD_VER:-}" \
    "code_sha256=$GOT_SHA" \
    "cdk_invoked=false" \
    "rust_compiled=false"

echo "NEW_VERSION=$NEW_VER"
echo "CODE_SHA256=$GOT_SHA"
