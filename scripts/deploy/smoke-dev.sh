#!/usr/bin/env bash
# Smoke tests for schema-infra after deploy.
# Exit 0 only if critical surfaces respond as expected on the NEW stack.
set -euo pipefail

ENVIRONMENT="${1:-${SCHEMA_SMOKE_ENV:-dev}}"
case "$ENVIRONMENT" in
  prod) DEFAULT_REGION="us-east-1" ;;
  dev) DEFAULT_REGION="us-west-2" ;;
  *) echo "FAIL: unknown smoke environment: $ENVIRONMENT" >&2; exit 1 ;;
esac

REGION="${AWS_REGION:-$DEFAULT_REGION}"
STACK="SchemaServiceStack-$ENVIRONMENT"

API_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceApiUrl`].OutputValue' \
  --output text)

if [ -z "$API_URL" ] || [ "$API_URL" = "None" ]; then
  echo "FAIL: no SchemaServiceApiUrl for $STACK" >&2
  exit 1
fi

echo "== schema smoke-$ENVIRONMENT against $API_URL =="

fail=0
check() {
  local path="$1" expect_code="$2" expect_substr="${3:-}"
  local code body
  body=$(curl -sS -m 45 -w "\n%{http_code}" "${API_URL}${path}" || echo -e "\n000")
  code=$(echo "$body" | tail -1)
  body=$(echo "$body" | sed '$d')
  if [ "$code" != "$expect_code" ]; then
    echo "FAIL $path: HTTP $code (want $expect_code) body=$(echo "$body" | cut -c1-120)"
    fail=1
    return
  fi
  if [ -n "$expect_substr" ] && ! echo "$body" | grep -q "$expect_substr"; then
    echo "FAIL $path: missing '$expect_substr' in body=$(echo "$body" | cut -c1-120)"
    fail=1
    return
  fi
  echo "OK   $path HTTP $code"
}

# Healthy core surfaces
check "/v1/health" "200" "healthy"
check "/health" "200" "healthy"
check "/v1/schemas" "200" "schemas"

# Dead planes must NOT be served by Lambda as success (APIGW or Lambda 404 both OK)
# After canary CDK: APIGW 404 for unmounted routes. Before: Lambda may return JSON 404.
for path in /v1/views /v1/transforms /api/schemas; do
  code=$(curl -sS -m 20 -o /dev/null -w "%{http_code}" "${API_URL}${path}" || echo 000)
  case "$code" in
    404|403) echo "OK   $path HTTP $code (dead surface)" ;;
    *) echo "FAIL $path: HTTP $code (dead surface should 404)"; fail=1 ;;
  esac
done

# Shared-only must be mounted (auth may 401/403 without key — not APIGW 404)
code=$(curl -sS -m 20 -o /tmp/schema-shared-only.out -w "%{http_code}" \
  "${API_URL}/v1/snapshot/shared-only" || echo 000)
case "$code" in
  200|401|403) echo "OK   /v1/snapshot/shared-only HTTP $code (mounted)" ;;
  404)
    # Allow brief lag if stage not updated yet; still fail hard for smoke
    echo "FAIL /v1/snapshot/shared-only HTTP 404 (route missing on gateway)"
    fail=1
    ;;
  *) echo "FAIL /v1/snapshot/shared-only HTTP $code"; fail=1 ;;
esac

if [ "$ENVIRONMENT" = "prod" ]; then
  DOMAIN=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceDomain`].OutputValue' \
    --output text 2>/dev/null || true)
  DOMAIN_TARGET=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceDomainTarget`].OutputValue' \
    --output text 2>/dev/null || true)

  if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "None" ] && \
     [ -n "$DOMAIN_TARGET" ] && [ "$DOMAIN_TARGET" != "None" ]; then
    code=$(curl -sS -m 20 \
      --connect-to "${DOMAIN}:443:${DOMAIN_TARGET}:443" \
      -o /tmp/schema-shared-only-domain.out \
      -w "%{http_code}" \
      "https://${DOMAIN}/v1/snapshot/shared-only" || echo 000)
    case "$code" in
      200|401|403) echo "OK   ${DOMAIN}/v1/snapshot/shared-only HTTP $code (mounted)" ;;
      404)
        echo "FAIL ${DOMAIN}/v1/snapshot/shared-only HTTP 404 (custom-domain route missing)"
        fail=1
        ;;
      *) echo "FAIL ${DOMAIN}/v1/snapshot/shared-only HTTP $code"; fail=1 ;;
    esac
  else
    echo "FAIL: missing prod custom-domain outputs for $STACK"
    fail=1
  fi
fi

# Schema resolve must be mounted. This is a public read/dedupe route used by
# fresh Mini nodes during first app-schema declaration; APIGW 404 breaks init.
code=$(curl -sS -m 20 -o /tmp/schema-resolve.out -w "%{http_code}" \
  -X POST "${API_URL}/v1/schemas/resolve" \
  -H 'Content-Type: application/json' \
  -d '{"client_registry_version":null,"proposals":[]}' || echo 000)
case "$code" in
  200|400) echo "OK   /v1/schemas/resolve HTTP $code (mounted)" ;;
  404)
    echo "FAIL /v1/schemas/resolve HTTP 404 (route missing on gateway)"
    fail=1
    ;;
  *) echo "FAIL /v1/schemas/resolve HTTP $code"; fail=1 ;;
esac

# PoW clients must be able to obtain the stateless mutation challenge. An
# empty payload is intentionally invalid, but must reach Lambda (400), not the
# API Gateway missing-route response (404).
code=$(curl -sS -m 20 -o /tmp/schema-mutation-challenge.out -w "%{http_code}" \
  -X POST "${API_URL}/v1/schemas/mutation-challenge" \
  -H 'Content-Type: application/json' -d '{}' || echo 000)
case "$code" in
  400) echo "OK   /v1/schemas/mutation-challenge HTTP 400 (mounted)" ;;
  404)
    echo "FAIL /v1/schemas/mutation-challenge HTTP 404 (route missing on gateway)"
    fail=1
    ;;
  *) echo "FAIL /v1/schemas/mutation-challenge HTTP $code"; fail=1 ;;
esac

# Public app shelf (lastdb app list). Lambda returns the promoted, non-revoked
# array. APIGW `{"message":"Not Found"}` means GET was never mounted on /v1/apps
# (POST-only was the long-standing bug after fold #682).
code=$(curl -sS -m 20 -o /tmp/schema-apps-list.out -w "%{http_code}" \
  "${API_URL}/v1/apps" || echo 000)
body=$(cat /tmp/schema-apps-list.out 2>/dev/null || true)
case "$code" in
  200)
    if echo "$body" | grep -q '\['; then
      echo "OK   /v1/apps HTTP 200 (public shelf mounted)"
    else
      echo "FAIL /v1/apps: HTTP 200 but body is not a JSON array: $(echo "$body" | cut -c1-120)"
      fail=1
    fi
    ;;
  404)
    if echo "$body" | grep -q '"message"[[:space:]]*:[[:space:]]*"Not Found"'; then
      echo "FAIL /v1/apps HTTP 404 APIGW missing-route (mount GET on /v1/apps)"
    else
      echo "FAIL /v1/apps HTTP 404 body=$(echo "$body" | cut -c1-120)"
    fi
    fail=1
    ;;
  *) echo "FAIL /v1/apps HTTP $code body=$(echo "$body" | cut -c1-120)"; fail=1 ;;
esac

# PUT /v1/apps/{app_id} must reach Lambda (cert-gated), not APIGW 404.
# Empty body without cert → Lambda 401/400; never gateway {"message":"Not Found"}.
code=$(curl -sS -m 20 -o /tmp/schema-apps-put.out -w "%{http_code}" \
  -X PUT "${API_URL}/v1/apps/__smoke_missing_app__" \
  -H 'Content-Type: application/json' -d '{}' || echo 000)
body=$(cat /tmp/schema-apps-put.out 2>/dev/null || true)
case "$code" in
  400|401|404)
    if [ "$code" = "404" ] && echo "$body" | grep -q '"message"[[:space:]]*:[[:space:]]*"Not Found"'; then
      echo "FAIL PUT /v1/apps/{app_id} HTTP 404 APIGW missing-route (mount PUT)"
      fail=1
    else
      echo "OK   PUT /v1/apps/{app_id} HTTP $code (mounted; Lambda auth/validation)"
    fi
    ;;
  *)
    echo "FAIL PUT /v1/apps/{app_id} HTTP $code body=$(echo "$body" | cut -c1-120)"
    fail=1
    ;;
esac

# Anthropic env must be gone on the live function
FN=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`SchemaServiceFunctionName`].OutputValue' --output text)
if [ -n "$FN" ] && [ "$FN" != "None" ]; then
  has=$(aws lambda get-function-configuration --function-name "$FN" --region "$REGION" \
    --query 'Environment.Variables.ANTHROPIC_API_KEY_SECRET_ARN' --output text 2>/dev/null || echo "None")
  if [ "$has" = "None" ] || [ -z "$has" ] || [ "$has" = "null" ]; then
    echo "OK   no ANTHROPIC_API_KEY_SECRET_ARN on function env"
  else
    echo "FAIL ANTHROPIC_API_KEY_SECRET_ARN still set on Lambda env"
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "schema smoke-$ENVIRONMENT FAILED"
  exit 1
fi
echo "schema smoke-$ENVIRONMENT PASSED"
