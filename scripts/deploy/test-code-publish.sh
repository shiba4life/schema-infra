#!/usr/bin/env bash
# No-AWS regression tests for the code-only Lambda publish path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/code-publish-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export LASTGIT_DEPLOY_LOG_DIR="$TMP/deploy-log"
export SCHEMA_DEPLOY_TELEMETRY_FILE="$TMP/telemetry.jsonl"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin" "$TMP/artifact"

cat > "$TMP/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${MOCK_AWS_LOG:?}"

svc="${1:-}"
op="${2:-}"
case "$svc $op" in
  "cloudformation describe-stacks")
    stack=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --stack-name) stack="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    case "$stack" in
      SchemaServiceStack-dev) echo "schema-service-dev" ;;
      SchemaServiceStack-prod) echo "schema-service-prod" ;;
      *) echo "None" ;;
    esac
    ;;
  "lambda get-alias")
    echo "${MOCK_ALIAS_VERSION:-41}"
    ;;
  "lambda update-function-code")
    echo "${MOCK_UPDATE_CODE_SHA:-$MOCK_EXPECTED_SHA}"
    ;;
  "lambda wait")
    exit 0
    ;;
  "lambda get-function-configuration")
    echo "${MOCK_DEPLOYED_SHA:-$MOCK_EXPECTED_SHA}"
    ;;
  "lambda publish-version")
    echo "${MOCK_PUBLISH_VERSION:-42}"
    ;;
  "lambda update-alias")
    exit 0
    ;;
  "lambda get-provisioned-concurrency-config")
    exit 1
    ;;
  "lambda get-function")
    exit 0
    ;;
  *)
    echo "unhandled aws call: $*" >&2
    exit 99
    ;;
esac
AWS
chmod +x "$TMP/bin/aws"

write_artifact() {
  local payload="$1"
  printf '%s' "$payload" > "$TMP/artifact/bootstrap.zip"
  MOCK_EXPECTED_SHA="$(openssl dgst -sha256 -binary "$TMP/artifact/bootstrap.zip" | base64)"
  export MOCK_EXPECTED_SHA
  cat > "$TMP/artifact/manifest.json" <<EOF
{
  "artifact_code_sha256_b64": "$MOCK_EXPECTED_SHA"
}
EOF
}

reset_logs() {
  : > "$TMP/aws.log"
  : > "$SCHEMA_DEPLOY_TELEMETRY_FILE"
  export MOCK_AWS_LOG="$TMP/aws.log"
  unset MOCK_DEPLOYED_SHA MOCK_UPDATE_CODE_SHA MOCK_ALIAS_VERSION MOCK_PUBLISH_VERSION
}

assert_no_aws_calls() {
  if [ -s "$TMP/aws.log" ]; then
    echo "FAIL: expected no AWS calls" >&2
    cat "$TMP/aws.log" >&2
    exit 1
  fi
}

assert_no_alias_update() {
  if grep -q '^lambda update-alias' "$TMP/aws.log"; then
    echo "FAIL: alias update should not have been called" >&2
    cat "$TMP/aws.log" >&2
    exit 1
  fi
}

write_artifact "artifact-v1"
reset_logs
printf 'tampered' > "$TMP/artifact/bootstrap.zip"
set +e
bash "$ROOT/scripts/deploy/code-publish.sh" dev us-west-2 "$TMP/artifact/manifest.json" \
  >"$TMP/byte-mismatch.out" 2>"$TMP/byte-mismatch.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: byte mismatch should fail" >&2; exit 1; }
grep -q 'artifact bytes do not match manifest' "$TMP/byte-mismatch.err"
assert_no_aws_calls
echo "ok byte-mismatch stops before AWS"

write_artifact "artifact-v2"
reset_logs
export MOCK_DEPLOYED_SHA="not-the-manifest-sha"
set +e
bash "$ROOT/scripts/deploy/code-publish.sh" dev us-west-2 "$TMP/artifact/manifest.json" \
  >"$TMP/deployed-mismatch.out" 2>"$TMP/deployed-mismatch.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: deployed CodeSha256 mismatch should fail" >&2; exit 1; }
grep -q 'deployed CodeSha256' "$TMP/deployed-mismatch.err"
assert_no_alias_update
echo "ok deployed-sha-mismatch leaves alias untouched"

write_artifact "artifact-v3"
reset_logs
out="$(bash "$ROOT/scripts/deploy/code-publish.sh" dev us-west-2 "$TMP/artifact/manifest.json")"
printf '%s\n' "$out" | grep -q '^NEW_VERSION=42$'
printf '%s\n' "$out" | grep -q "^CODE_SHA256=$MOCK_EXPECTED_SHA$"
grep -q '^lambda update-function-code' "$TMP/aws.log"
grep -q '^lambda publish-version' "$TMP/aws.log"
grep -q '^lambda update-alias' "$TMP/aws.log"
grep -q '"event":"code_publish"' "$SCHEMA_DEPLOY_TELEMETRY_FILE"
grep -q '"cdk_invoked":"false"' "$SCHEMA_DEPLOY_TELEMETRY_FILE"
grep -q '"rust_compiled":"false"' "$SCHEMA_DEPLOY_TELEMETRY_FILE"
echo "ok dev code-only publish records no-CDK/no-compile evidence"

echo "ok code-publish tests"
