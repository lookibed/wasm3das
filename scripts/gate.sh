#!/usr/bin/env bash
# Daslang quality gate for wasm3das. The single definition of the gate: CI
# (.github/workflows/daslang-quality.yml) and the pre-push hook
# (.githooks/pre-push) both call this script, so the two can not drift.
#
# Environment:
#   DASLANG_ROOT   required: the git checkout of GaijinEntertainment/daScript
#                  at the commit pinned in scripts/daslang_pin, built in place
#                  (verify: scripts/verify_daslang.sh)
#   DASLANG        compiler binary (default: $DASLANG_ROOT/bin/daslang)
#   DASLANG_ALLOW_UNPINNED=1  run against a different checkout (local
#                  experiments only; CI and the hook never set it)
#
# Usage: scripts/gate.sh [stage ...]
#   stages: compile lint-paranoid lint-perf lint-style test invariants
#   no argument runs every stage in that order.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

DASLANG_ROOT="${DASLANG_ROOT:-}"
DASLANG="${DASLANG:-${DASLANG_ROOT:+$DASLANG_ROOT/bin/daslang}}"
export DAS_LINT_CONFIG_PATH="${DAS_LINT_CONFIG_PATH:-$repo_root/.lint_config}"

# The gate is defined for exactly one compiler: the daslang source pinned in
# scripts/daslang_pin, built in the checkout the user verifies and points at.
# The checkout HEAD matching the pin is the proof it is that one.
"$repo_root/scripts/verify_daslang.sh"
DASLANG="${DASLANG:-$DASLANG_ROOT/bin/daslang}"
echo "gate: daslang $("$DASLANG" --version)"

stage_compile() {
    echo "gate: compiler diagnostics"
    while IFS= read -r file; do
        "$DASLANG" -compile-only "$file" >/dev/null
    done < <(find source tests/integration app tests/host_test -type f -name '*.das' -print | sort)
}

stage_lint() {
    local profile="$1"
    echo "gate: lint --$profile"
    "$DASLANG" "$DASLANG_ROOT/utils/lint/main.das" -- --"$profile" source tests/integration app tests/host_test
}

stage_test() {
    echo "gate: project tests"
    "$DASLANG" "$DASLANG_ROOT/dastest/dastest.das" -- --test tests/integration
}

stage_invariants() {
    echo "gate: repository invariants"
    DASLANG="$DASLANG" DASLANG_ROOT="$DASLANG_ROOT" "$repo_root/scripts/check_repo_invariants.sh" "$repo_root"
}

run_stage() {
    case "$1" in
        compile)        stage_compile ;;
        lint-paranoid)  stage_lint paranoid-only ;;
        lint-perf)      stage_lint perf-only ;;
        lint-style)     stage_lint style-only ;;
        test)           stage_test ;;
        invariants)     stage_invariants ;;
        *) echo "gate: unknown stage '$1'" >&2; exit 2 ;;
    esac
}

if [[ $# -eq 0 ]]; then
    set -- compile lint-paranoid lint-perf lint-style test invariants
fi

for stage in "$@"; do
    run_stage "$stage"
done

echo "gate: passed (${*})"
