#!/usr/bin/env bash
# Gate 2 of the Eden port: upstream-test coverage (see coverage.py).
# Usage: scripts/eden/coverage.sh [module ...]
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
banner "coverage: upstream tests have Eden counterparts"
exec python3 "$repo/scripts/eden/coverage.py" "$repo" "$@"
