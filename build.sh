#!/usr/bin/env bash
#
# Build script for schema service infrastructure.
#
# Drives the full pre-deploy artifact assembly:
#   1. Init / update the `fold/` submodule (the EdgeVector/fold monorepo,
#      pinned to main). Contains schema_service crates + fold_db crates
#      in one cargo workspace, so no sibling-fold_db checkout is needed.
#   2. Build the Lambda zip from `fold/schema_service/crates/server_lambda/`
#      (runs cargo-lambda inside Amazon Linux 2023 so ort-sys, which
#      fastembed pulls in, links against the Lambda runtime glibc). Cargo
#      intermediates stay in container-local /tmp; only the final lambda zip is
#      written back to fold/target/lambda for CDK.
#   3. Extract the zip to `fold/target/lambda/server_lambda-extracted/`
#      which is the path CDK reads via `Code.fromAsset(...)`.
#   4. Download the fastembed model files into `target/fastembed_layer/`
#      (at schema-infra repo root). CDK reads this via Code.fromAsset.
#
# Usage:
#   ./build.sh                    # release build
#   ./build.sh dev-release        # faster iteration profile
#   BUILD_PROFILE=dev-release ./build.sh
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/deploy/telemetry.sh
source "$SCRIPT_DIR/scripts/deploy/telemetry.sh"

PROFILE="${1:-${BUILD_PROFILE:-release}}"

echo "=== Schema Service artifact build ==="
echo "Profile: $PROFILE"
echo ""

# =============================================================
# 1. Submodule — the fold monorepo
# =============================================================
FOLD_DIR="$SCRIPT_DIR/fold"
if [ ! -f "$FOLD_DIR/Cargo.toml" ]; then
    echo "fold submodule not initialized, running git submodule update..."
    git submodule update --init --recursive -- fold
fi
echo "fold submodule at: $(git -C "$FOLD_DIR" rev-parse --short HEAD)"

# =============================================================
# 2. Lambda build inside Docker (AL2023 == Lambda runtime)
#
# cargo-lambda's default zig-based cross-compile cannot link ort-sys
# (fastembed's ONNX Runtime). We build natively inside the AL2023
# image, so the resulting binary matches the runtime glibc exactly.
#
# Layout inside the container:
#   /build/schema-infra/         ← this repo
#   /build/schema-infra/fold/    ← submodule (fold monorepo, self-contained;
#                                  contains both schema_service and fold_db
#                                  crates as one cargo workspace). Cargo
#                                  intermediates are not written to this bind
#                                  mount to avoid shared target-dir races.
# =============================================================
CACHE_DIR="$SCRIPT_DIR/.docker-cache"
mkdir -p "$CACHE_DIR/cargo" "$CACHE_DIR/rustup"

DOCKER_SCRIPT_DIR="$SCRIPT_DIR"
DOCKER_MIRROR_DIR=""
needs_docker_mirror() {
    if [ "${SCHEMA_INFRA_DOCKER_MIRROR:-}" = "1" ]; then
        return 0
    fi
    case "$(uname -s):$SCRIPT_DIR" in
        Darwin:/private/var/folders/*|Darwin:/var/folders/*)
            return 0
            ;;
    esac
    return 1
}

prepare_docker_mirror() {
    local hash
    hash="$(printf '%s' "$SCRIPT_DIR" | shasum -a 256 | awk '{print substr($1, 1, 16)}')"
    DOCKER_MIRROR_DIR="${SCHEMA_INFRA_DOCKER_MIRROR_DIR:-$HOME/.cache/schema-infra/docker-build/$hash}"
    mkdir -p "$DOCKER_MIRROR_DIR"
    echo "Docker cannot reliably bind-mount this checkout path; mirroring to $DOCKER_MIRROR_DIR"
    rsync -a --delete \
        --exclude '/.git/' \
        --exclude '/.docker-cache/' \
        --exclude '/target/' \
        --exclude '/fold/target/' \
        --exclude '/cdk/node_modules/' \
        "$SCRIPT_DIR"/ "$DOCKER_MIRROR_DIR"/
    mkdir -p "$DOCKER_MIRROR_DIR/.docker-cache/cargo" "$DOCKER_MIRROR_DIR/.docker-cache/rustup"
    DOCKER_SCRIPT_DIR="$DOCKER_MIRROR_DIR"
}

copy_mirror_lambda_artifact() {
    if [ -z "$DOCKER_MIRROR_DIR" ]; then
        return 0
    fi
    local mirror_lambda_dir="$DOCKER_MIRROR_DIR/fold/target/lambda"
    if [ ! -d "$mirror_lambda_dir" ]; then
        echo "ERROR: mirrored Docker build did not produce $mirror_lambda_dir" >&2
        exit 1
    fi
    mkdir -p "$FOLD_DIR/target/lambda"
    rsync -a --delete "$mirror_lambda_dir"/ "$FOLD_DIR/target/lambda"/
}

if [ -n "${SCHEMA_BUILD_REMOTE_HOST:-}" ]; then
    # Deploy-path decision decision-schema-infra-deploy-path-native-x86-pc:
    # run the identical container build on a native x86_64 Linux builder.
    # The pin comes from the committed gitlink so the remote build cannot
    # drift from what this checkout pins, even before submodule init.
    echo ""
    echo "=== Building Lambda zip (remote native x86_64: $SCHEMA_BUILD_REMOTE_HOST) ==="
    FOLD_PIN="$(git -C "$SCRIPT_DIR" ls-tree HEAD fold | awk '{print $3}')"
    if [ -z "$FOLD_PIN" ]; then
        echo "ERROR: could not resolve fold submodule pin from git ls-tree" >&2
        exit 1
    fi
    stage_started="$(schema_telemetry_stage_start build)"
    BUILD_PROFILE="$PROFILE" "$SCRIPT_DIR/scripts/remote-native-build.sh" "$FOLD_PIN" "$FOLD_DIR"
    schema_telemetry_stage_end build "$stage_started"
else
    if needs_docker_mirror; then
        prepare_docker_mirror
    fi

    echo ""
    echo "=== Building Lambda zip (Docker: amazonlinux:2023) ==="
    stage_started="$(schema_telemetry_stage_start build)"
    docker run --rm \
        --platform linux/amd64 \
        -v "$DOCKER_SCRIPT_DIR":/build/schema-infra \
        -w /build/schema-infra/fold \
        -e CARGO_HOME=/build/schema-infra/.docker-cache/cargo \
        -e RUSTUP_HOME=/build/schema-infra/.docker-cache/rustup \
        -e BUILD_PROFILE="$PROFILE" \
        -e GH_PAT="${GH_PAT:-}" \
        amazonlinux:2023 \
        bash /build/schema-infra/scripts/lambda-container-build.sh
    schema_telemetry_stage_end build "$stage_started"

    copy_mirror_lambda_artifact
fi

# =============================================================
# 3. Extract bootstrap.zip for CDK Code.fromAsset(...)
# =============================================================
ZIP_PATH="$FOLD_DIR/target/lambda/server_lambda/bootstrap.zip"
EXTRACTED_DIR="$FOLD_DIR/target/lambda/server_lambda-extracted"

if [ ! -f "$ZIP_PATH" ]; then
    echo "ERROR: Lambda build did not produce $ZIP_PATH"
    exit 1
fi

rm -rf "$EXTRACTED_DIR"
mkdir -p "$EXTRACTED_DIR"
unzip -o "$ZIP_PATH" -d "$EXTRACTED_DIR/" > /dev/null

SIZE_MB=$(( $(stat -f%z "$ZIP_PATH" 2>/dev/null || stat -c%s "$ZIP_PATH") / 1024 / 1024 ))
echo ""
echo "=== Lambda artifact ==="
echo "Zip:       $ZIP_PATH (${SIZE_MB}MB)"
echo "Extracted: $EXTRACTED_DIR"
ls -la "$EXTRACTED_DIR"
"$SCRIPT_DIR/scripts/deploy/dependency-budget.sh"

# =============================================================
# 4. Fastembed Layer — download model files into the Layer
#    artifact directory CDK reads via lambda.Code.fromAsset.
#
# Per Phase 1 D2 the Layer source lives in schema-infra (this repo)
# because the Layer is a deploy concern. Output path is
# target/fastembed_layer/ at the repo root.
# =============================================================
HF_REPO="Qdrant/all-MiniLM-L6-v2-onnx"
# Pinned so a model.onnx change upstream can't silently break the Lambda —
# update this hash deliberately when you want a new model version.
HF_REVISION="5f1b8cd78bc4fb444dd171e59b18f3a3af89a079"
MODEL_FILES=(model.onnx tokenizer.json config.json special_tokens_map.json tokenizer_config.json)

LAYER_DIR="$SCRIPT_DIR/target/fastembed_layer"
CACHE_ROOT="$LAYER_DIR/fastembed_cache/models--Qdrant--all-MiniLM-L6-v2-onnx"
SNAPSHOT_DIR="$CACHE_ROOT/snapshots/$HF_REVISION"
mkdir -p "$SNAPSHOT_DIR" "$CACHE_ROOT/refs"
echo -n "$HF_REVISION" > "$CACHE_ROOT/refs/main"

echo ""
echo "=== Fastembed Layer ==="
# Durability: the model files are cached across CI runs by GitHub Actions
# cache (see deploy.yml's "Cache fastembed model" step, keyed on the pinned
# HF_REVISION). On a cache HIT the files are already present below and we skip
# the network entirely — HuggingFace is only ever contacted on a cold cache
# (first run, a deliberate revision bump, or a ~7-day cache eviction). When we
# DO hit the network, HF rate-limits CI runners hard (HTTP 429) — a single
# bare `curl` made the whole prod deploy flap (4 consecutive 429 failures,
# 2026-06-04). So the cold path retries with exponential backoff.
download_with_retry() {
    local url="$1" target="$2"
    local attempts=6 delay=5 i
    for ((i = 1; i <= attempts; i++)); do
        if curl -fsSL -o "$target" "$url"; then
            return 0
        fi
        rm -f "$target"
        echo "    attempt $i/$attempts failed; retrying in ${delay}s" >&2
        [ "$i" -lt "$attempts" ] && sleep "$delay" && delay=$((delay * 2))
    done
    return 1
}
for f in "${MODEL_FILES[@]}"; do
    target="$SNAPSHOT_DIR/$f"
    if [ -s "$target" ]; then
        echo "  [cached] $f"
        continue
    fi
    url="https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$f"
    echo "  [download] $f"
    download_with_retry "$url" "$target" || {
        echo "ERROR: failed to download $f from HuggingFace after retries." >&2
        echo "       HF is likely rate-limiting (429). The GitHub Actions cache" >&2
        echo "       (deploy.yml) normally serves this so HF is rarely hit; if" >&2
        echo "       this is a cold cache, re-run once the rate limit clears." >&2
        exit 1
    }
done
echo "Layer dir: $LAYER_DIR"
ls -la "$SNAPSHOT_DIR"

echo ""
echo "=== Build complete ==="
echo "Ready to deploy with: ./deploy.sh [dev|prod]"
