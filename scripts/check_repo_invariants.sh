#!/usr/bin/env bash
# Repository invariants for wasm3das, run as the `invariants` stage of
# scripts/gate.sh (CI and pre-push). Each check reports every violation it
# finds; the script exits non-zero if any check failed.
#
# This script reads .das files with shell tools. That is a CI/hook mechanism
# only: the tooling policy in AGENTS.md (Daslang-aware tools for reading and
# editing .das) is unchanged for agents.
#
# Environment (same as scripts/gate.sh):
#   DASLANG        pinned compiler binary
#   DASLANG_ROOT   toolchain root with utils/das-fmt/
# Usage: scripts/check_repo_invariants.sh [repo_root]
set -uo pipefail

repo_root="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

DASLANG_ROOT="${DASLANG_ROOT:-$repo_root/tmp/daslang-toolchain}"
DASLANG="${DASLANG:-$DASLANG_ROOT/bin/daslang}"

failures=0
fail() {
    echo "invariant: $*" >&2
    failures=$((failures + 1))
}

# 1. Formatter verify. dasfmt must be given directories: a single-file path
#    aborts with "FATAL: g_envTotal=1 at exit" on the pinned toolchain.
echo "invariants: formatter verify"
for dir in source tests/integration app host_test; do
    if ! "$DASLANG" "$DASLANG_ROOT/utils/das-fmt/dasfmt.das" -- --path "$dir" --verify; then
        fail "unformatted files under $dir/ (run mcp__daslang__format_file on them)"
    fi
done

# 2. Test discovery. dastest runs only [test] functions; a file without the
#    attribute compiles but contributes zero tests (this hid 15 tests once).
echo "invariants: test discovery"
for file in tests/integration/test_*.das; do
    if ! grep -q '^\[test\]' "$file"; then
        fail "$file has no [test] function; dastest would run nothing from it"
    fi
    if ! grep -q '^require dastest/testing_boost' "$file"; then
        fail "$file does not require dastest/testing_boost"
    fi
done

# 3. Manifest consistency. Every source file has a manifest row; every test
#    file maps to a source file unless allow-listed as an integration test.
echo "invariants: manifest consistency"
for file in source/*.das; do
    if ! grep -qF "\`$file\`" PORTING_MANIFEST.md; then
        fail "$file has no row in PORTING_MANIFEST.md"
    fi
done
integration_tests="test_m3_types_integration test_fib32_regression test_lang_modules test_spec_modules_load test_spec_core"
for file in tests/integration/test_*.das; do
    stem="$(basename "$file" .das)"
    layer="${stem#test_}"
    case " $integration_tests " in
        *" $stem "*) continue ;;
    esac
    if [[ ! -f "source/$layer.das" ]]; then
        fail "$file has no source/$layer.das; add the layer or allow-list the test as integration"
    fi
done

# 4. File header. AGENTS.md code conventions: every .das starts with
#    `options gen2` and `options indenting = 4`.
echo "invariants: file headers"
for file in source/*.das tests/integration/*.das app/*.das host_test/*.das; do
    if [[ "$(sed -n '1p' "$file")" != "options gen2" ]]; then
        fail "$file: line 1 must be 'options gen2'"
    fi
    if [[ "$(sed -n '2p' "$file")" != "options indenting = 4" ]]; then
        fail "$file: line 2 must be 'options indenting = 4'"
    fi
done

if (( failures > 0 )); then
    echo "invariants: $failures violation(s)" >&2
    exit 1
fi
echo "invariants: passed"
