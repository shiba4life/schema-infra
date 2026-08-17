#!/usr/bin/env bash
# Canonical input-digest for schema-infra Lambda artifacts.
# Sourced by ensure-artifact.sh; tests drive these functions directly.
# Changing any hashed file (or the fold pin / profile) must change the digest.

schema_infra_sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

# Prints the exact bytes hashed into input_digest.
# $1 = repo root, $2 = fold pin oid, $3 = profile
schema_infra_artifact_input_text() {
    local root="${1:?}" fold_pin="${2:?}" profile="${3:?}"
    printf 'fold=%s\nrecipe=%s\ndriver=%s\nlib=%s\nbuilder=%s\nprofile=%s\n' \
        "$fold_pin" \
        "$(schema_infra_sha256_file "$root/scripts/lambda-container-build.sh")" \
        "$(schema_infra_sha256_file "$root/scripts/remote-native-build.sh")" \
        "$(schema_infra_sha256_file "$root/scripts/lambda-container-build-lib.sh")" \
        "$(schema_infra_sha256_file "$root/scripts/ensure-builder-image.sh")" \
        "$profile"
}

schema_infra_input_digest() {
    schema_infra_artifact_input_text "$@" | {
        shasum -a 256 2>/dev/null || sha256sum
    } | awk '{print $1}'
}
