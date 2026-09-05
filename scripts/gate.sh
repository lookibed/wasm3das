#!/usr/bin/env bash
# Daslang quality gate for wasm3das. The single definition of the gate: CI
# (.github/workflows/daslang-quality.yml) and the pre-push hook
# (.githooks/pre-push) both call this script, so the two can not drift.
#
# Environment:
#   DASLANG        pinned compiler binary        (default: tmp/daslang-toolchain/bin/daslang)
#   DASLANG_ROOT   toolchain root with utils/ and dastest/ (default: tmp/daslang-toolchain)
#
# Usage: scripts/gate.sh [stage ...]
#   stages: compile lint-paranoid lint-perf lint-style test invariants
#   no argument runs every stage in that order.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

DASLANG_ROOT="${DASLANG_ROOT:-$repo_root/tmp/daslang-toolchain}"
DASLANG="${DASLANG:-$DASLANG_ROOT/bin/daslang}"
export DAS_LINT_CONFIG_PATH="${DAS_LINT_CONFIG_PATH:-$repo_root/.lint_config}"

if [[ ! -x "$DASLANG" ]]; then
    echo "gate: missing pinned Daslang compiler at $DASLANG" >&2
    exit 1
fi

stage_compile() {
    echo "gate: compiler diagnostics"
    while IFS= read -r file; do
        "$DASLANG" -compile-only "$file" >/dev/null
    done < <(find source tests -type f -name '*.das' -print | sort)
}

stage_lint() {
    local profile="$1"
    echo "gate: lint --$profile"
    "$DASLANG" "$DASLANG_ROOT/utils/lint/main.das" -- --"$profile" source tests
}

stage_test() {
    echo "gate: project tests"
    "$DASLANG" "$DASLANG_ROOT/dastest/dastest.das" -- --test tests
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
