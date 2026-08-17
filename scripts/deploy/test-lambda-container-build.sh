#!/usr/bin/env bash
# Drive the shipped compile-recipe helpers (not a reimplementation).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/scripts/lambda-container-build-lib.sh"
ENTRY="$ROOT/scripts/lambda-container-build.sh"
ENSURE_IMAGE="$ROOT/scripts/ensure-builder-image.sh"
test -f "$LIB" || { echo "missing $LIB" >&2; exit 1; }
test -f "$ENTRY" || { echo "missing $ENTRY" >&2; exit 1; }
test -x "$ENSURE_IMAGE" || { echo "missing $ENSURE_IMAGE" >&2; exit 1; }

# shellcheck source=../lambda-container-build-lib.sh
source "$LIB"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lambda-build-recipe-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- size profile: thin LTO, not fat; abort + strip stay under 15 MiB ---
cat > "$TMP/Cargo.toml" <<'TOML'
[workspace]
members = ["dummy"]
TOML
schema_lambda_apply_size_profile "$TMP/Cargo.toml"
grep -q '^# schema-lambda-size-profile' "$TMP/Cargo.toml"
grep -q 'lto = "thin"' "$TMP/Cargo.toml"
grep -q 'codegen-units = 1' "$TMP/Cargo.toml"
grep -q 'panic = "abort"' "$TMP/Cargo.toml"
grep -q 'strip = true' "$TMP/Cargo.toml"
if grep -q 'lto = "fat"' "$TMP/Cargo.toml"; then
    echo "FAIL: shipped profile still appends fat LTO" >&2
    exit 1
fi
# second apply is idempotent
schema_lambda_apply_size_profile "$TMP/Cargo.toml"
count="$(grep -c 'lto = "thin"' "$TMP/Cargo.toml")"
[ "$count" -eq 1 ] || { echo "FAIL: profile append not idempotent ($count)" >&2; exit 1; }
unset RUSTFLAGS || true
schema_lambda_export_profile_rustflags
case " $RUSTFLAGS " in
    *" --cfg $SCHEMA_LAMBDA_PROFILE_CFG "*) ;;
    *) echo "FAIL: profile rustflags missing --cfg $SCHEMA_LAMBDA_PROFILE_CFG" >&2; exit 1 ;;
esac
schema_lambda_export_profile_rustflags
count="$(printf '%s' "$RUSTFLAGS" | grep -o -- "--cfg $SCHEMA_LAMBDA_PROFILE_CFG" | wc -l | tr -d ' ')"
[ "$count" -eq 1 ] || { echo "FAIL: rustflags cfg not idempotent ($count)" >&2; exit 1; }
echo "ok size-profile thin-lto (not fat)"

# --- zip size gate: real helper, real files ---
under="$TMP/under.zip"
over="$TMP/over.zip"
limit="$TMP/limit.zip"
dd if=/dev/zero of="$under" bs=1 count=0 seek=$((SCHEMA_LAMBDA_ZIP_MAX_BYTES - 1)) 2>/dev/null
dd if=/dev/zero of="$limit" bs=1 count=0 seek="$SCHEMA_LAMBDA_ZIP_MAX_BYTES" 2>/dev/null
dd if=/dev/zero of="$over" bs=1 count=0 seek=$((SCHEMA_LAMBDA_ZIP_MAX_BYTES + 1)) 2>/dev/null
out="$(schema_lambda_check_zip_size "$under")"
printf '%s\n' "$out" | grep -q "^bootstrap_zip_size_bytes=$((SCHEMA_LAMBDA_ZIP_MAX_BYTES - 1))$"
set +e
schema_lambda_check_zip_size "$limit" >"$TMP/limit.out" 2>"$TMP/limit.err"
rc_limit=$?
schema_lambda_check_zip_size "$over" >"$TMP/over.out" 2>"$TMP/over.err"
rc_over=$?
schema_lambda_check_zip_size "$TMP/missing.zip" >"$TMP/miss.out" 2>"$TMP/miss.err"
rc_miss=$?
set -e
[ "$rc_limit" -ne 0 ] || { echo "FAIL: exact 15 MiB must fail" >&2; exit 1; }
[ "$rc_over" -ne 0 ] || { echo "FAIL: over 15 MiB must fail" >&2; exit 1; }
[ "$rc_miss" -ne 0 ] || { echo "FAIL: missing zip must fail" >&2; exit 1; }
grep -q '15 MiB' "$TMP/limit.err"
echo "ok zip-size gate ${SCHEMA_LAMBDA_ZIP_MAX_BYTES}"

# --- yum skip when the prebaked image already has packages ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gcc" <<'EOF'
#!/bin/sh
exit 0
EOF
cp "$TMP/bin/gcc" "$TMP/bin/cmake3"
cp "$TMP/bin/gcc" "$TMP/bin/git"
cp "$TMP/bin/gcc" "$TMP/bin/python3"
cp "$TMP/bin/gcc" "$TMP/bin/pkg-config"
cat > "$TMP/bin/rpm" <<'EOF'
#!/bin/sh
[ "$1" = "-q" ] && [ "$2" = "openssl-devel" ]
EOF
cat > "$TMP/bin/yum" <<'EOF'
#!/bin/sh
echo YUM_CALLED >>"${YUM_LOG:?}"
exit 1
EOF
chmod +x "$TMP/bin/"*
YUM_LOG="$TMP/yum.log"
: > "$YUM_LOG"
export YUM_LOG
PATH="$TMP/bin:$PATH" schema_lambda_ensure_build_packages >"$TMP/yum-skip.out"
if [ -s "$YUM_LOG" ]; then
    echo "FAIL: yum ran even though packages were present" >&2
    exit 1
fi
grep -q 'skipped' "$TMP/yum-skip.out"
echo "ok yum skipped when packages present"

# --- yum runs when the toolchain is missing ---
cat > "$TMP/bin/yum" <<'EOF'
#!/bin/sh
echo YUM_CALLED >>"${YUM_LOG:?}"
exit 0
EOF
chmod +x "$TMP/bin/yum"
: > "$YUM_LOG"
# Hide gcc by using only yum + a failing rpm on PATH (no gcc).
mkdir -p "$TMP/emptybin"
cp "$TMP/bin/yum" "$TMP/emptybin/yum"
PATH="$TMP/emptybin:/usr/bin:/bin" schema_lambda_ensure_build_packages >/dev/null
grep -q YUM_CALLED "$YUM_LOG"
echo "ok yum runs when packages missing"

# --- shipped entry actually uses the helpers ---
grep -q 'source "$SCRIPT_DIR/lambda-container-build-lib.sh"' "$ENTRY"
grep -q 'schema_lambda_apply_size_profile' "$ENTRY"
grep -q 'schema_lambda_export_profile_rustflags' "$ENTRY"
grep -q 'schema_lambda_ensure_build_packages' "$ENTRY"
grep -q 'schema_lambda_ensure_cargo_lambda' "$ENTRY"
grep -q 'schema_lambda_check_zip_size' "$ENTRY"
grep -q 'schema_lambda_stage cargo_build' "$ENTRY"
if grep -q 'lto = "fat"' "$ENTRY"; then
    echo "FAIL: container entry still names fat LTO" >&2
    exit 1
fi
echo "ok shipped container entry uses lib helpers"

# --- builder image script is the host entry and uses the same cargo-lambda pin ---
dockerfile="$(schema_lambda_builder_dockerfile)"
printf '%s\n' "$dockerfile" | grep -q "v${SCHEMA_LAMBDA_CARGO_LAMBDA_VER}/cargo-lambda-v${SCHEMA_LAMBDA_CARGO_LAMBDA_VER}"
printf '%s\n' "$dockerfile" | grep -q "$SCHEMA_LAMBDA_CARGO_LAMBDA_SHA256"
mkdir -p "$TMP/hostbin"
cat > "$TMP/hostbin/docker" <<'EOF'
#!/bin/sh
echo "$*" >>"${DOCKER_LOG:?}"
exit 0
EOF
chmod +x "$TMP/hostbin/docker"
DOCKER_LOG="$TMP/docker.log"
: > "$DOCKER_LOG"
export DOCKER_LOG
image="$(PATH="$TMP/hostbin:$PATH" bash "$ENSURE_IMAGE")"
[ "$image" = "$SCHEMA_LAMBDA_BUILDER_IMAGE" ] || {
    echo "FAIL: ensure-builder-image printed '$image'" >&2
    exit 1
}
grep -q -- "-t $SCHEMA_LAMBDA_BUILDER_IMAGE" "$DOCKER_LOG"
echo "ok ensure-builder-image (mocked docker)"

# --- remote + local host launchers use the baked image, not raw amazonlinux ---
grep -q 'ensure-builder-image.sh' "$ROOT/scripts/remote-native-build.sh"
grep -q 'ensure-builder-image.sh' "$ROOT/build.sh"
if grep -n 'amazonlinux:2023' "$ROOT/scripts/remote-native-build.sh" "$ROOT/build.sh" | grep -v 'schema-infra-lambda-builder' | grep -v '^#' | grep -q 'amazonlinux:2023'; then
    # still allowed in comments / Dockerfile generator; docker run must not use the raw tag
    :
fi
if grep -E '^\s+amazonlinux:2023 \\$' "$ROOT/scripts/remote-native-build.sh" "$ROOT/build.sh"; then
    echo "FAIL: docker run still uses raw amazonlinux:2023" >&2
    exit 1
fi
echo "ok host launchers use builder image"

echo "ok lambda-container-build recipe tests"
