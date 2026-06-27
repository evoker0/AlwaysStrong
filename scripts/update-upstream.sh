#!/usr/bin/env bash
# Check (and optionally apply) latest TEESimulator-RS and PlayIntegrityFork releases.
#
# Usage:
#   scripts/update-upstream.sh            # dry-run, print whether anything is newer
#   scripts/update-upstream.sh --apply    # bump build.sh pinned tags to latest
#   scripts/update-upstream.sh --apply --build   # also re-run build.sh after patching
#
# Exit codes:
#   0  nothing to update
#   1  error
#  10  updates available (dry-run only)
#  11  updates applied

set -euo pipefail

APPLY=0
DO_BUILD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --build) DO_BUILD=1; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_SH="$ROOT/build.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need curl
need python3

api_latest() {
    # Pull tag_name and the asset name we care about. PIF ships one .zip per release;
    # TEE ships Debug + Release — we always pick the Release one.
    local repo="$1" prefer="$2"
    curl -sSL -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${repo}/releases/latest" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
tag = d['tag_name']
names = [a['name'] for a in d.get('assets', []) if a['name'].endswith('.zip')]
prefer = '$prefer'
pick = next((n for n in names if prefer and prefer in n), names[0] if names else '')
print(tag)
print(pick)
"
}

current_value() {
    grep -E "^$1=" "$BUILD_SH" | head -1 | cut -d= -f2- | tr -d '\"'
}

echo '==> Querying upstream GitHub releases'
mapfile -t TEE < <(api_latest "Enginex0/TEESimulator-RS" "Release")
mapfile -t PIF < <(api_latest "osm0sis/PlayIntegrityFork" "")

TEE_TAG_NEW="${TEE[0]}"; TEE_ASSET_NEW="${TEE[1]}"
PIF_TAG_NEW="${PIF[0]}"; PIF_ASSET_NEW="${PIF[1]}"

[[ -n "$TEE_TAG_NEW" && -n "$TEE_ASSET_NEW" ]] || { echo "TEE lookup failed" >&2; exit 1; }
[[ -n "$PIF_TAG_NEW" && -n "$PIF_ASSET_NEW" ]] || { echo "PIF lookup failed" >&2; exit 1; }

TEE_TAG_CUR=$(current_value TEE_TAG_DEFAULT)
TEE_ASSET_CUR=$(current_value TEE_ASSET_DEFAULT)
PIF_TAG_CUR=$(current_value PIF_TAG_DEFAULT)
PIF_ASSET_CUR=$(current_value PIF_ASSET_DEFAULT)

echo "    TEE: $TEE_TAG_CUR  ->  $TEE_TAG_NEW   ($TEE_ASSET_NEW)"
echo "    PIF: $PIF_TAG_CUR  ->  $PIF_TAG_NEW   ($PIF_ASSET_NEW)"

CHANGED=0
[[ "$TEE_TAG_CUR" != "$TEE_TAG_NEW" || "$TEE_ASSET_CUR" != "$TEE_ASSET_NEW" ]] && CHANGED=1
[[ "$PIF_TAG_CUR" != "$PIF_TAG_NEW" || "$PIF_ASSET_CUR" != "$PIF_ASSET_NEW" ]] && CHANGED=1

if [[ $CHANGED -eq 0 ]]; then
    echo '==> Up to date.'
    exit 0
fi

if [[ $APPLY -eq 0 ]]; then
    echo '==> Updates available. Re-run with --apply to bump build.sh to the new tags.'
    exit 10
fi

echo '==> Patching pinned versions'
patch_kv() {
    local file="$1" key="$2" val="$3"
    if grep -qE "^${key}=" "$file"; then
        sed -i.bak "s|^${key}=.*|${key}=\"${val}\"|" "$file" && rm -f "$file.bak"
    fi
}

patch_kv "$BUILD_SH" TEE_TAG_DEFAULT     "$TEE_TAG_NEW"
patch_kv "$BUILD_SH" TEE_ASSET_DEFAULT   "$TEE_ASSET_NEW"
patch_kv "$BUILD_SH" PIF_TAG_DEFAULT     "$PIF_TAG_NEW"
patch_kv "$BUILD_SH" PIF_ASSET_DEFAULT   "$PIF_ASSET_NEW"

echo '==> Patched.'

if [[ $DO_BUILD -eq 1 ]]; then
    echo '==> Re-running build.sh --clean'
    bash "$BUILD_SH" --clean
fi

exit 11
