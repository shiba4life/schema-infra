#!/usr/bin/env bash
# Host-side: make sure the AL2023 compile image with yum deps + cargo-lambda
# exists so lambda-container-build.sh does not yum/install on every --rm run.
# Prints the image name on stdout; docker progress goes to stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lambda-container-build-lib.sh
source "$SCRIPT_DIR/lambda-container-build-lib.sh"

if ! command -v docker >/dev/null 2>&1; then
    echo "FAIL: docker is required to build $SCHEMA_LAMBDA_BUILDER_IMAGE" >&2
    exit 1
fi

schema_lambda_builder_dockerfile | docker build -t "$SCHEMA_LAMBDA_BUILDER_IMAGE" -f- "$SCRIPT_DIR" >&2
printf '%s\n' "$SCHEMA_LAMBDA_BUILDER_IMAGE"
