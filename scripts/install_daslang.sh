#!/usr/bin/env bash
# Install the pinned daslang release bundle (scripts/daslang_release.env) into
# tmp/daslang. This is the only way daslang reaches this repository: the same
# prebuilt asset serves the gate, the launchers, CI, the release bundles and
# the MCP/LSP tooling, and nothing is ever built from the daScript sources.
#
# Usage: scripts/install_daslang.sh [platform] [--force]
#   platform  linux-x86_64 | linux-arm64 | windows-x86_64 | darwin26-arm64
#             (default: detected from uname)
#   --force   reinstall even when the installed stamp already matches
#
# Environment:
#   DASLANG_ROOT   install location (default: tmp/daslang)
#   DASLANG_DOWNLOAD_DIR  where the zip is kept (default: tmp/daslang-download)
#
# The install writes <DASLANG_ROOT>/.wasm3das-release with "<tag> <platform>";
# scripts/gate.sh checks that stamp against the pinned tag.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=daslang_release.env
source "$repo_root/scripts/daslang_release.env"

platform=""
force=0
for arg in "$@"; do
    case "$arg" in
        --force) force=1 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) platform="$arg" ;;
    esac
done

if [[ -z "$platform" ]]; then
    case "$(uname -s):$(uname -m)" in
        Linux:x86_64)                   platform=linux-x86_64 ;;
        Linux:aarch64|Linux:arm64)      platform=linux-arm64 ;;
        Darwin:arm64)                   platform=darwin26-arm64 ;;
        MINGW*|MSYS*|CYGWIN*)           platform=windows-x86_64 ;;
        *) echo "install_daslang: unsupported platform $(uname -s) $(uname -m); pass one explicitly" >&2; exit 2 ;;
    esac
fi

sha_var="DASLANG_SHA256_${platform//-/_}"
expected_sha="${!sha_var:-}"
if [[ -z "$expected_sha" ]]; then
    echo "install_daslang: no checksum for platform '$platform' in scripts/daslang_release.env" >&2
    exit 2
fi

dest="${DASLANG_ROOT:-$repo_root/tmp/daslang}"
download_dir="${DASLANG_DOWNLOAD_DIR:-$repo_root/tmp/daslang-download}"
asset="daslang-bundle-$platform.zip"
url="https://github.com/$DASLANG_RELEASE_REPO/releases/download/$DASLANG_RELEASE/$asset"
zip="$download_dir/$DASLANG_RELEASE-$asset"
stamp="$dest/.wasm3das-release"
want_stamp="$DASLANG_RELEASE $platform"

binary="$dest/bin/daslang"
[[ "$platform" == windows-* ]] && binary="$dest/bin/daslang.exe"

if [[ $force -eq 0 && -f "$stamp" && -f "$binary" && "$(cat "$stamp")" == "$want_stamp" ]]; then
    echo "install_daslang: $dest already holds $want_stamp"
    exit 0
fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

mkdir -p "$download_dir"
if [[ -f "$zip" && "$(sha256_of "$zip")" == "$expected_sha" ]]; then
    echo "install_daslang: reusing $zip"
else
    echo "install_daslang: downloading $url"
    curl -fL --retry 3 --progress-bar -o "$zip.part" "$url"
    mv -f "$zip.part" "$zip"
fi

actual_sha="$(sha256_of "$zip")"
if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "install_daslang: checksum mismatch for $asset" >&2
    echo "  expected $expected_sha" >&2
    echo "  actual   $actual_sha" >&2
    exit 1
fi
echo "install_daslang: checksum verified"

unpack="$dest.unpack"
rm -rf "$dest" "$unpack"
mkdir -p "$unpack"
if command -v unzip >/dev/null 2>&1; then
    unzip -q "$zip" -d "$unpack"
elif command -v 7z >/dev/null 2>&1; then
    7z x -bso0 -bsp0 -o"$unpack" "$zip"
else
    python3 -m zipfile -e "$zip" "$unpack"
fi

# The zip holds a single top-level directory (daslang_bundle/); it becomes tmp/daslang.
top="$(find "$unpack" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "$top" || ! -d "$top/daslib" ]]; then
    echo "install_daslang: unexpected bundle layout under $unpack" >&2
    exit 1
fi
mv "$top" "$dest"
rm -rf "$unpack"
chmod +x "$dest"/bin/* 2>/dev/null || true
printf '%s\n' "$want_stamp" > "$stamp"

echo "install_daslang: installed $want_stamp into $dest"
"$binary" --version
