#!/usr/bin/env bash
#
# Lambda build steps that run INSIDE the amazonlinux:2023 container.
#
# Invoked by build.sh's `docker run` with this repo mounted at
# /build/schema-infra and the working directory set to
# /build/schema-infra/fold (the fold monorepo submodule).
#
# History: this used to live inline in build.sh as a single-quoted
# `bash -c '...'` string. That made apostrophes in comments fatal — an
# apostrophe in a comment (fold's) terminated the quoted string early,
# so the remainder executed in the OUTER shell and tripped `set -u` on
# $CARGO_HOME (the 2026-06-12 deploy outage, third quoting incident in
# this block). A real file has no such hazard and is shellcheck-able.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lambda-container-build-lib.sh
source "$SCRIPT_DIR/lambda-container-build-lib.sh"

# Defensively bind the env this script depends on. The docker run passes
# these via -e, but they were observed UNBOUND inside the container
# 2026-06-12 (set -u tripped on CARGO_HOME). An unbound CARGO_HOME makes
# `cargo install` drop the binary in the default ~/.cargo/bin instead of
# the .docker-cache/cargo/bin that PATH below covers, so every later
# invocation hits "command not found". Pin them to the same literals the
# docker -e flags use so the rest of the script is robust whether or not
# -e propagated.
export CARGO_HOME="${CARGO_HOME:-/build/schema-infra/.docker-cache/cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-/build/schema-infra/.docker-cache/rustup}"
export BUILD_PROFILE="${BUILD_PROFILE:-release}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/schema-infra-cargo-target}"
export LAMBDA_DIR="${LAMBDA_DIR:-/build/schema-infra/fold/target/lambda}"
# Docker Desktop runs this x86_64 image through QEMU on Apple Silicon. Parallel
# Cargo occasionally leaves a fork-before-exec child permanently blocked on a
# futex under that emulation, wedging the single-concurrency deploy queue. Keep
# the Lambda build serial by default; native runners can explicitly raise the
# value after proving their platform does not exhibit the QEMU deadlock.
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}"
# Thin LTO + one codegen unit + abort/strip: keeps the 15 MiB zip bar without
# the fat-LTO serial link that dominated the 2026-08-06 3936s stage:build.
# Appended to the BUILD-SIDE fold workspace manifest (disposable build input,
# never committed). Manifest profiles are the only override cargo-lambda
# honors here — CARGO_PROFILE_* env and a CARGO_HOME config profile were
# measured as 0.2s no-ops. Idempotent via marker.
FOLD_MANIFEST="/build/schema-infra/fold/Cargo.toml"
schema_lambda_apply_size_profile "$FOLD_MANIFEST"
schema_lambda_export_profile_rustflags

schema_lambda_stage yum schema_lambda_ensure_build_packages

# Cargo needs to fetch private cross-repo git deps (e.g. exemem_common
# from EdgeVector/exemem-infra). Conditional on GH_PAT so local builds
# (no token) still work for fully-public-dep cases.
if [ -n "${GH_PAT:-}" ]; then
    git config --global url."https://x-access-token:${GH_PAT}@github.com/".insteadOf "https://github.com/"
fi

if [ ! -x /build/schema-infra/.docker-cache/cargo/bin/cargo ]; then
    schema_lambda_stage rustup \
        bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable 2>&1 | tail -1'
else
    echo "stage:rustup skipped (cargo already cached)"
fi
export PATH="/build/schema-infra/.docker-cache/cargo/bin:$PATH"

# Install cargo-lambda from its PREBUILT release binary, NOT `cargo install`
# (compile from source). The from-source path was a tar pit on the cache-miss
# path and caused a multi-hour prod-deploy outage 2026-06-12:
#   - it recompiles cargo-lambda + deps on every cache miss (the GH Actions
#     cache stores .docker-cache/cargo/{registry,git}, never bin/), so the
#     tool is never actually cached;
#   - that fresh compile broke on the `time 0.3.48` yank (E0119 under stable
#     rustc);
#   - and even with that fixed, `cargo install` reported writing the binary to
#     .docker-cache/cargo/bin/cargo-lambda but that dir did not exist
#     afterward inside the same container — the runner bind mount did not
#     persist the write.
# The prebuilt musl build is a single static binary. Drop it on /usr/local/bin
# (always on PATH, not bind-mounted, no CARGO_HOME dependency), sha256-pinned
# so a tampered/rotated asset fails the build instead of shipping silently.
# Bump cl_ver + cl_sha together; the sha is published at <asset>.sha256.
schema_lambda_stage cargo-lambda schema_lambda_ensure_cargo_lambda

# --locked: build schema_service against fold's committed Cargo.lock instead
# of re-resolving. Without it the AL2023 build picks up whatever the registry
# serves that day — which broke the deploy 2026-06-12 when `time 0.3.48`
# shipped (E0119 conflicting From impls under stable rustc). fold pins
# `time 0.3.47`; honor it so resolution drift fails as a deliberate lockfile
# bump, not a silent prod-deploy outage. cargo-lambda forwards --locked
# through to the underlying `cargo build`.
#
# Invoke via the `cargo lambda` SUBCOMMAND form, not `cargo-lambda build`
# directly: cargo-lambda is a cargo subcommand whose clap expects argv[1]
# to be `lambda` (cargo supplies it). `cargo-lambda build` skips that and
# errors "unrecognized subcommand 'build'". `cargo lambda build` works now
# that the prebuilt binary is reliably on PATH (/usr/local/bin); the rustup
# cargo resolves it. Verified in an isolated AL2023 container.
#
# Always enable FastEmbed for live resolve (native_component_cover@1). The
# model is served from the dedicated Lambda Layer at /opt/fastembed_cache.
# The transform-wasm feature was removed from fold; do not reintroduce
# ENABLE_TRANSFORM_WASM here.
echo "Building with --features fastembed (native_component_cover resolve requires live embeddings)"
echo "Cargo target dir: $CARGO_TARGET_DIR"
echo "Lambda artifact dir: $LAMBDA_DIR"
echo "Cargo build jobs: $CARGO_BUILD_JOBS"
mkdir -p "$CARGO_TARGET_DIR" "$LAMBDA_DIR"

# Keep CARGO_TARGET_DIR as an environment setting. cargo-lambda 1.9.1 forwards
# its --target-dir CLI flag to `cargo metadata`, but that Cargo subcommand does
# not accept --target-dir and the deploy-pipeline fails before compilation.
schema_lambda_stage cargo_build \
    cargo lambda build \
        --profile "$BUILD_PROFILE" \
        --output-format zip \
        --lambda-dir "$LAMBDA_DIR" \
        --target x86_64-unknown-linux-gnu \
        --compiler cargo \
        --locked \
        -p schema_service_server_lambda \
        --features fastembed

# Repack at maximum deflate. cargo-lambda zips at the default level; the
# bootstrap binary is already stripped, so the remaining budget lever with
# zero runtime-behavior risk is compression (North Star bar: zip < 15 MiB).
ZIP_OUT="$LAMBDA_DIR/server_lambda/bootstrap.zip"
if [ -f "$ZIP_OUT" ]; then
    python3 - "$ZIP_OUT" <<'PY'
import os, sys, zipfile
src = sys.argv[1]
tmp = src + ".repack"
with zipfile.ZipFile(src) as zin, \
     zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zout:
    for info in zin.infolist():
        zout.writestr(info, zin.read(info.filename))
before, after = os.path.getsize(src), os.path.getsize(tmp)
if after < before:
    os.replace(tmp, src)
    print(f"repacked bootstrap.zip: {before} -> {after} bytes")
else:
    os.remove(tmp)
    print(f"repack not smaller ({before} -> {after}); keeping original")
PY
fi
schema_lambda_check_zip_size "$ZIP_OUT"
chmod -R a+rwX "$LAMBDA_DIR" 2>/dev/null || true
