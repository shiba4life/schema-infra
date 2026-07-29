#!/usr/bin/env bash
# Ensure the fastembed model Layer asset exists at target/fastembed_layer
# for CDK Code.fromAsset — extracted from build.sh so the CDK deploy path
# can run with a prebuilt Lambda artifact (--skip-build) without invoking
# the whole build (release #2's 8-second CDK failure: fresh scratch had the
# zip but no layer directory).
#
# Durability: model files are mirrored in a host-side cache keyed by the
# pinned HF revision, so per-event scratch checkouts never re-download.
# HuggingFace is contacted only on a truly cold cache, with retry/backoff
# (HF 429s made a prod deploy flap 2026-06-04).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

HF_REPO="Qdrant/all-MiniLM-L6-v2-onnx"
# Pinned so a model.onnx change upstream can't silently break the Lambda —
# update this hash deliberately when you want a new model version.
HF_REVISION="5f1b8cd78bc4fb444dd171e59b18f3a3af89a079"
MODEL_FILES=(model.onnx tokenizer.json config.json special_tokens_map.json tokenizer_config.json)

LAYER_DIR="$SCRIPT_DIR/target/fastembed_layer"
CACHE_ROOT="$LAYER_DIR/fastembed_cache/models--Qdrant--all-MiniLM-L6-v2-onnx"
SNAPSHOT_DIR="$CACHE_ROOT/snapshots/$HF_REVISION"
HOST_CACHE="${SCHEMA_LAYER_CACHE:-$HOME/.lastgit/deploy-schema-infra/fastembed-layer-cache}/$HF_REVISION"

mkdir -p "$SNAPSHOT_DIR" "$CACHE_ROOT/refs" "$HOST_CACHE"
echo -n "$HF_REVISION" > "$CACHE_ROOT/refs/main"

echo "=== Fastembed Layer ==="
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
    cached="$HOST_CACHE/$f"
    if [ -s "$target" ]; then
        echo "  [present] $f"
        continue
    fi
    if [ -s "$cached" ]; then
        cp -f "$cached" "$target"
        echo "  [host-cache] $f"
        continue
    fi
    url="https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$f"
    echo "  [download] $f"
    download_with_retry "$url" "$target" || {
        echo "ERROR: failed to download $f from HuggingFace after retries." >&2
        echo "       HF is likely rate-limiting (429); retry once it clears." >&2
        exit 1
    }
    cp -f "$target" "$cached"
done
echo "Layer dir: $LAYER_DIR"
