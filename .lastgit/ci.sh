#!/usr/bin/env bash
# LastGit merge gate for schema-infra (not deploy).
set -euo pipefail
cd "$(dirname "$0")/.."

# Compatibility guard for older LastGit watchers: deploy-pipeline statuses must
# run the deploy script, never the merge gate. Newer LastGit resolves
# `.lastgit/<context>.sh` directly; this branch catches stale runners that still
# invoke `.lastgit/ci.sh` for every context.
if [ "${LASTGIT_CI_CONTEXT:-ci-required}" = "deploy-pipeline" ]; then
  exec .lastgit/deploy-pipeline.sh
fi

shopt -s nullglob 2>/dev/null || true
echo "== shell syntax =="
for f in ./*.sh .lastgit/*.sh scripts/*.sh scripts/deploy/*.sh \
  scripts/proof/*/*.sh tests/proof/*/*.sh; do
  [ -e "$f" ] || continue
  echo "bash -n $f"
  bash -n "$f"
done
echo "== canary helper tests =="
bash scripts/deploy/test-code-publish.sh
bash scripts/deploy/test-canary-weight-pin.sh
bash scripts/deploy/test-canary-alarm-gate.sh
bash scripts/deploy/test-canary-run-root.sh
bash scripts/deploy/test-prove-mutation-gate.sh
echo "== compile-recipe tests =="
bash scripts/deploy/test-lambda-container-build.sh
bash scripts/deploy/test-artifact-digest.sh
echo "== release classifier tests =="
bash scripts/deploy/test-classify-change.sh
echo "== terminal proof harness =="
bash tests/proof/schema-lambda-fast-deployment/test-prove.sh
echo "== npm/cdk compile =="
npm_version="$(npm --version)"
case "$npm_version" in 10.*|9.*) ;; *) echo "warn: npm $npm_version";; esac
if [ -f cdk/package.json ]; then
  npm --prefix cdk ci --ignore-scripts
  npm --prefix cdk run build
fi
echo "lastgit ci gate PASSED"
