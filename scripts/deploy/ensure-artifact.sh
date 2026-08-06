#!/usr/bin/env bash
# Ensure the Lambda artifact for this checkout's input digest exists, building
# it exactly once per digest (design-schema-lambda-fast-deployment §1).
#
# The input digest identifies everything that can change the artifact:
#   fold submodule pin OID + container build recipe + remote build driver +
#   build profile. One digest → one build → one immutable cached zip + manifest,
#   reused by dev, prod, and every later release that pins the same inputs
#   (the terminal proof's builds_for_digest=1).
#
# Cache layout (append-only; never overwrite an existing digest):
#   ${SCHEMA_ARTIFACT_STORE:-~/.lastgit/deploy-schema-infra/artifacts}/<digest>/
#     bootstrap.zip
#     manifest.json      (no secret values: oids, digests, sizes, timestamps)
#
# Usage (from repo root):  scripts/deploy/ensure-artifact.sh
# Prints the manifest path on success; the zip is also copied to the
# legacy in-tree location fold/target/lambda/server_lambda/bootstrap.zip so
# deploy.sh --skip-build and CDK Code.fromAsset keep working unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/deploy/telemetry.sh
source "$SCRIPT_DIR/scripts/deploy/telemetry.sh"

PROFILE="${BUILD_PROFILE:-release}"
STORE="${SCHEMA_ARTIFACT_STORE:-$HOME/.lastgit/deploy-schema-infra/artifacts}"

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

FOLD_PIN="$(git ls-tree HEAD fold | awk '{print $3}')"
if [ -z "$FOLD_PIN" ]; then
    echo "FAIL: cannot resolve fold submodule pin" >&2
    exit 1
fi
RECIPE_SHA="$(sha256_file scripts/lambda-container-build.sh)"
DRIVER_SHA="$(sha256_file scripts/remote-native-build.sh)"
INPUT_DIGEST="$(printf 'fold=%s\nrecipe=%s\ndriver=%s\nprofile=%s\n' \
    "$FOLD_PIN" "$RECIPE_SHA" "$DRIVER_SHA" "$PROFILE" | \
    { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}')"

DIGEST_DIR="$STORE/$INPUT_DIGEST"
ZIP_CACHED="$DIGEST_DIR/bootstrap.zip"
MANIFEST="$DIGEST_DIR/manifest.json"
IN_TREE_ZIP="$SCRIPT_DIR/fold/target/lambda/server_lambda/bootstrap.zip"
IN_TREE_EXTRACTED="$SCRIPT_DIR/fold/target/lambda/server_lambda-extracted"

materialize_in_tree() {
    # deploy.sh --skip-build and CDK Code.fromAsset read both the zip and
    # the extracted directory; keep that contract for the CDK path.
    mkdir -p "$(dirname "$IN_TREE_ZIP")"
    cp -f "$1" "$IN_TREE_ZIP"
    rm -rf "$IN_TREE_EXTRACTED"
    mkdir -p "$IN_TREE_EXTRACTED"
    unzip -o "$IN_TREE_ZIP" -d "$IN_TREE_EXTRACTED/" > /dev/null
}

emit_manifest() {
    local zip_path="$1" cache_state="$2"
    local zip_sha zip_b64 zip_size
    zip_sha="$(sha256_file "$zip_path")"
    zip_b64="$(openssl dgst -sha256 -binary "$zip_path" | base64)"
    zip_size="$(stat -f%z "$zip_path" 2>/dev/null || stat -c%s "$zip_path")"
    mkdir -p "$DIGEST_DIR"
    cat > "$MANIFEST" <<EOF
{
  "schema_version": 1,
  "input_digest": "$INPUT_DIGEST",
  "schema_infra_oid": "$(git rev-parse HEAD)",
  "fold_oid": "$FOLD_PIN",
  "build_recipe_sha256": "$RECIPE_SHA",
  "build_driver_sha256": "$DRIVER_SHA",
  "profile": "$PROFILE",
  "artifact_sha256_hex": "$zip_sha",
  "artifact_code_sha256_b64": "$zip_b64",
  "artifact_size_bytes": $zip_size,
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "builder": "${SCHEMA_BUILD_REMOTE_HOST:+remote:$SCHEMA_BUILD_REMOTE_HOST}",
  "cache": "$cache_state"
}
EOF
    schema_telemetry_emit artifact_ready \
        "input_digest=$INPUT_DIGEST" \
        "artifact_sha256=$zip_sha" \
        "artifact_size_bytes=$zip_size" \
        "cache=$cache_state" >&2
}

if [ -s "$ZIP_CACHED" ] && [ -s "$MANIFEST" ]; then
    # Cache hit: verify integrity against the recorded digest before reuse.
    want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifact_sha256_hex"])' "$MANIFEST")"
    got="$(sha256_file "$ZIP_CACHED")"
    if [ "$want" = "$got" ]; then
        schema_telemetry_emit artifact_ready \
            "input_digest=$INPUT_DIGEST" \
            "artifact_sha256=$got" \
            "cache=hit" >&2
        materialize_in_tree "$ZIP_CACHED"
        echo "CACHE=hit"
        echo "MANIFEST=$MANIFEST"
        exit 0
    fi
    echo "WARN: cached artifact digest mismatch (want=$want got=$got) — rebuilding" >&2
fi

# Cache miss: build once (remote native by default), then freeze the result.
# Tip-executed default — see build.sh. Supervisor LaunchAgent need not be reinstalled.
SCHEMA_BUILD_REMOTE_HOST="${SCHEMA_BUILD_REMOTE_HOST-pc}"
export SCHEMA_BUILD_REMOTE_HOST
stage_started="$(schema_telemetry_stage_start artifact_build)"
if [ -n "${SCHEMA_BUILD_REMOTE_HOST:-}" ]; then
    BUILD_PROFILE="$PROFILE" "$SCRIPT_DIR/scripts/remote-native-build.sh" "$FOLD_PIN" "$SCRIPT_DIR/fold"
else
    BUILD_PROFILE="$PROFILE" "$SCRIPT_DIR/build.sh" "$PROFILE" >/dev/null
fi
schema_telemetry_stage_end artifact_build "$stage_started"

if [ ! -s "$IN_TREE_ZIP" ]; then
    echo "FAIL: build produced no $IN_TREE_ZIP" >&2
    exit 1
fi
mkdir -p "$DIGEST_DIR"
cp -f "$IN_TREE_ZIP" "$ZIP_CACHED"
emit_manifest "$ZIP_CACHED" miss
materialize_in_tree "$ZIP_CACHED"
echo "CACHE=miss"
echo "MANIFEST=$MANIFEST"
