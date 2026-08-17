#!/usr/bin/env bash
# Classify a schema-infra release into one of three deploy paths.
#
# Design: design-schema-lambda-fast-deployment §3 ("Split code and
# infrastructure paths"). The North Star terminal proof requires code-only
# releases to record cdk_invoked=false and rust_compiled=false, so the
# pipeline must know — before doing any expensive work — which plane a
# change belongs to:
#
#   code-only        artifact inputs changed (the fold submodule pin),
#                    CDK/config/layer inputs did not. Publish code versions
#                    and alias routing only; never run CDK.
#   infrastructure   CDK, deploy machinery, layer or config inputs changed.
#                    Run CDK referencing the prebuilt artifact; never
#                    compile Rust inside the CDK path.
#   no-impact        docs/tests/proofs/frontend only. Skip deployment with
#                    an explicit successful reason.
#
# Usage:
#   classify-change.sh <base-oid> <head-oid> [repo-dir]
#
# Prints one line:  <kind>\t<reason>
#   kind ∈ {code-only, infrastructure, no-impact}
# Exit 0 on success (any kind), non-zero on git errors.
#
# Rules are prefix-based on `git diff --name-only base..head`:
#   - infrastructure prefixes win over everything (mixed changes take the
#     conservative CDK path; it is idempotent and safe).
#   - the fold gitlink alone (or with no-impact paths) is code-only.
#   - only no-impact prefixes → no-impact.
#   - an EMPTY diff (base == head or no changed paths) → no-impact.
#   - unknown paths → infrastructure (fail conservative, never silently
#     fast-path a change we did not model).
set -euo pipefail

BASE="${1:?usage: classify-change.sh <base-oid> <head-oid> [repo-dir]}"
HEAD_OID="${2:?usage: classify-change.sh <base-oid> <head-oid> [repo-dir]}"
REPO_DIR="${3:-.}"

# Deploy machinery, CDK app, and layer inputs: the CDK/infrastructure plane.
is_infrastructure_path() {
    case "$1" in
        cdk/*|deploy.sh|build.sh|.lastgit/*|scripts/deploy/*|scripts/lambda-container-build.sh|scripts/lambda-container-build-lib.sh|scripts/remote-native-build.sh|scripts/ensure-builder-image.sh)
            return 0 ;;
    esac
    return 1
}

# Surfaces with no deployment impact at all.
is_no_impact_path() {
    case "$1" in
        docs/*|proofs/*|tests/*|frontend/*|README.md|AGENTS.md|*.md)
            return 0 ;;
        scripts/proof/*)
            return 0 ;;
    esac
    return 1
}

# The Lambda artifact input: the fold monorepo submodule pin.
is_code_path() {
    [ "$1" = "fold" ]
}

if ! git -C "$REPO_DIR" cat-file -e "$BASE^{commit}" 2>/dev/null; then
    printf 'infrastructure\tbase oid %s unknown — conservative full path\n' "$BASE"
    exit 0
fi

changed="$(git -C "$REPO_DIR" diff --name-only "$BASE" "$HEAD_OID" --)"

if [ -z "$changed" ]; then
    printf 'no-impact\tno changed paths between %.12s and %.12s\n' "$BASE" "$HEAD_OID"
    exit 0
fi

has_infra=0
has_code=0
has_unknown=0
unknown_example=""
infra_example=""
while IFS= read -r path; do
    [ -z "$path" ] && continue
    if is_infrastructure_path "$path"; then
        has_infra=1
        [ -z "$infra_example" ] && infra_example="$path"
    elif is_code_path "$path"; then
        has_code=1
    elif is_no_impact_path "$path"; then
        :
    else
        has_unknown=1
        [ -z "$unknown_example" ] && unknown_example="$path"
    fi
done <<EOF
$changed
EOF

if [ "$has_infra" = 1 ]; then
    printf 'infrastructure\tdeploy/CDK inputs changed (e.g. %s)\n' "$infra_example"
elif [ "$has_unknown" = 1 ]; then
    printf 'infrastructure\tunmodeled path changed (e.g. %s) — conservative full path\n' "$unknown_example"
elif [ "$has_code" = 1 ]; then
    printf 'code-only\tfold submodule pin changed; CDK inputs unchanged\n'
else
    printf 'no-impact\tonly docs/tests/proofs/frontend changed\n'
fi
