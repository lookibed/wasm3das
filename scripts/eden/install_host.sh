#!/usr/bin/env bash
# Installs the Eden host into the Eden project root:
#   - main.das from .eden_host/main.das, with the fixture list of
#     docs/eden-port/fixtures.txt generated between the FIXTURES markers
#   - every fixture as assets/wasm/<name>.data (a copy of wasm3c/test/<name>)
#
# The editor imports .data files as binary assets on its next rescan (a game
# restart is enough) and get_binary_asset returns their bytes. Nothing else
# in the project is touched.
#
# Usage: scripts/eden/install_host.sh [--check]
#   --check  report what would change, change nothing; exit 1 if anything would
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

check=0
[[ "${1:-}" == "--check" ]] && check=1
changed=0

# --- fixtures ---
mapfile -t fixtures < <(grep -vE '^\s*(#|$)' "$FIXTURES" | sed 's/\s*#.*$//; s/^\s*//; s/\s*$//')
for name in "${fixtures[@]}"; do
    src="$repo/wasm3c/test/$name"
    dst="$eden_root/assets/wasm/$name.data"
    if [[ ! -f "$src" ]]; then
        echo "install_host: fixture missing in wasm3c/test: $name" >&2
        exit 2
    fi
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
        echo "fixture: $name -> assets/wasm/$name.data"
        changed=1
        if [[ $check == 0 ]]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
        fi
    fi
done

# --- main.das ---
tmp="$(mktemp)"
{
    while IFS= read -r line; do
        printf '%s\n' "$line"
        if [[ "$line" == *"// FIXTURES-BEGIN"* ]]; then
            for name in "${fixtures[@]}"; do
                printf '    push(fixtureNames, "%s")\n' "$name"
            done
            # skip until the END marker
            while IFS= read -r skip; do
                if [[ "$skip" == *"// FIXTURES-END"* ]]; then
                    printf '%s\n' "$skip"
                    break
                fi
            done
        fi
    done < "$repo/.eden_host/main.das"
} > "$tmp"
if [[ ! -f "$eden_root/main.das" ]] || ! cmp -s "$tmp" "$eden_root/main.das"; then
    echo "main.das: updated from .eden_host/main.das (${#fixtures[@]} fixtures)"
    changed=1
    if [[ $check == 0 ]]; then
        cp "$tmp" "$eden_root/main.das"
    fi
fi
rm -f "$tmp"

if [[ $changed == 0 ]]; then
    echo "install_host: up to date"
    exit 0
fi
if [[ $check == 1 ]]; then
    echo "install_host: out of date (run without --check)"
    exit 1
fi
echo "install_host: installed; the editor picks the files up on the next game restart"
