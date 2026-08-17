#!/usr/bin/env bash
# Shared compile-recipe helpers for the schema Lambda.
# Sourced by scripts/lambda-container-build.sh (the container entry) and by
# host-side tests / ensure-builder-image.sh. No work at source time.
#
# Dominant 2026-08-06 cost (oid 156780a6, stage:build=3936s) was the
# cargo-lambda link under fat LTO + codegen-units=1. Thin LTO keeps a
# single codegen unit and the 15 MiB zip bar without that serial link.

SCHEMA_LAMBDA_ZIP_MAX_BYTES="${SCHEMA_LAMBDA_ZIP_MAX_BYTES:-15728640}"
SCHEMA_LAMBDA_CARGO_LAMBDA_VER="${SCHEMA_LAMBDA_CARGO_LAMBDA_VER:-1.9.1}"
SCHEMA_LAMBDA_CARGO_LAMBDA_SHA256="${SCHEMA_LAMBDA_CARGO_LAMBDA_SHA256:-ff97518ea2b3c094fb385563f0784fef9191efcdc775101f4f80613820c050ec}"
SCHEMA_LAMBDA_BUILDER_IMAGE="${SCHEMA_LAMBDA_BUILDER_IMAGE:-schema-infra-lambda-builder:al2023}"
# Folded into rustc args so a size-profile change cannot reuse a previous
# release fingerprint (cargo-lambda left the 2026-08-07 fat-LTO binary
# "Finished in 0.78s" after Cargo.toml already said lto="thin").
SCHEMA_LAMBDA_PROFILE_CFG="${SCHEMA_LAMBDA_PROFILE_CFG:-schema_lambda_lto_thin}"

schema_lambda_export_profile_rustflags() {
    case " ${RUSTFLAGS:-} " in
        *" --cfg ${SCHEMA_LAMBDA_PROFILE_CFG} "*) ;;
        *) export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--cfg ${SCHEMA_LAMBDA_PROFILE_CFG}" ;;
    esac
}

schema_lambda_now_s() {
    date +%s
}

schema_lambda_stage() {
    local name="$1"
    shift
    local started ended
    started="$(schema_lambda_now_s)"
    "$@"
    ended="$(schema_lambda_now_s)"
    echo "stage:${name} duration_sec=$((ended - started))"
}

schema_lambda_size_profile() {
    cat <<'CFG'

# schema-lambda-size-profile (appended at build time by
# scripts/lambda-container-build.sh; never committed to fold)
[profile.release]
lto = "thin"
codegen-units = 1
panic = "abort"
strip = true
CFG
}

schema_lambda_apply_size_profile() {
    local manifest="${1:?schema_lambda_apply_size_profile <Cargo.toml>}"
    if ! grep -q "^# schema-lambda-size-profile" "$manifest" 2>/dev/null; then
        schema_lambda_size_profile >> "$manifest"
    fi
}

schema_lambda_file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

schema_lambda_check_zip_size() {
    local zip="${1:?schema_lambda_check_zip_size <bootstrap.zip>}"
    local size
    if [ ! -f "$zip" ]; then
        echo "FAIL: bootstrap.zip missing: $zip" >&2
        return 1
    fi
    size="$(schema_lambda_file_size "$zip")"
    echo "bootstrap_zip_size_bytes=$size"
    if [ "$size" -ge "$SCHEMA_LAMBDA_ZIP_MAX_BYTES" ]; then
        echo "FAIL: bootstrap.zip $size bytes >= ${SCHEMA_LAMBDA_ZIP_MAX_BYTES} (15 MiB)" >&2
        return 1
    fi
    return 0
}

schema_lambda_build_packages_present() {
    command -v gcc >/dev/null 2>&1 \
        && command -v cmake3 >/dev/null 2>&1 \
        && command -v git >/dev/null 2>&1 \
        && command -v python3 >/dev/null 2>&1 \
        && command -v pkg-config >/dev/null 2>&1 \
        && rpm -q openssl-devel >/dev/null 2>&1
}

schema_lambda_ensure_build_packages() {
    if schema_lambda_build_packages_present; then
        echo "stage:yum skipped (packages already present)"
        return 0
    fi
    yum install -y gcc gcc-c++ cmake3 openssl-devel pkg-config tar gzip bzip2-libs perl git python3 > /dev/null
}

schema_lambda_cargo_lambda_url() {
    printf 'https://github.com/cargo-lambda/cargo-lambda/releases/download/v%s/cargo-lambda-v%s.x86_64-unknown-linux-musl.tar.gz' \
        "$SCHEMA_LAMBDA_CARGO_LAMBDA_VER" "$SCHEMA_LAMBDA_CARGO_LAMBDA_VER"
}

schema_lambda_install_cargo_lambda() {
    local dest="${1:-/usr/local/bin}"
    local tarball="/tmp/cargo-lambda.tar.gz"
    curl -fsSL "$(schema_lambda_cargo_lambda_url)" -o "$tarball"
    echo "${SCHEMA_LAMBDA_CARGO_LAMBDA_SHA256}  ${tarball}" | sha256sum -c -
    tar -xzf "$tarball" -C "$dest" cargo-lambda
    chmod +x "$dest/cargo-lambda"
}

schema_lambda_ensure_cargo_lambda() {
    if command -v cargo-lambda >/dev/null 2>&1; then
        echo "stage:cargo-lambda skipped (already on PATH)"
        return 0
    fi
    schema_lambda_install_cargo_lambda /usr/local/bin
}

schema_lambda_builder_dockerfile() {
    cat <<EOF
FROM amazonlinux:2023
RUN yum install -y gcc gcc-c++ cmake3 openssl-devel pkg-config tar gzip bzip2-libs perl git python3 \\
    && yum clean all \\
    && rm -rf /var/cache/yum
RUN curl -fsSL $(schema_lambda_cargo_lambda_url) -o /tmp/cargo-lambda.tar.gz \\
    && echo "${SCHEMA_LAMBDA_CARGO_LAMBDA_SHA256}  /tmp/cargo-lambda.tar.gz" | sha256sum -c - \\
    && tar -xzf /tmp/cargo-lambda.tar.gz -C /usr/local/bin cargo-lambda \\
    && chmod +x /usr/local/bin/cargo-lambda \\
    && rm /tmp/cargo-lambda.tar.gz
EOF
}
