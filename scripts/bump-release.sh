#!/usr/bin/env bash
# Bump the module by one patch version and write an English changelog section
# from the upstream-change summary that update-upstream.sh left behind. Used by
# the upstream-update workflow so a fresh PIF / TEESimulator release turns into
# an automatic AlwaysStrong release with real notes.
#
# Reads:   module/module.prop (version, versionCode), the summary file.
# Writes:  module/module.prop (bumped), CHANGELOG.md (new ## section at top).
# Prints:  the new version tag (e.g. v1.0.5). In CI, also appends
#          new_ver / new_code to $GITHUB_OUTPUT.
#
# Usage:  scripts/bump-release.sh ["extra note line" ...]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROP="$ROOT/module/module.prop"
CHANGELOG="$ROOT/CHANGELOG.md"
SUMMARY="${UPSTREAM_SUMMARY:-$ROOT/.upstream-changes.txt}"

cur_ver=$(sed -n 's/^version=//p'     "$PROP" | head -1)   # e.g. v1.0.4
cur_code=$(sed -n 's/^versionCode=//p' "$PROP" | head -1)  # e.g. 104
[[ -n "$cur_ver" && -n "$cur_code" ]] || { echo "cannot read version from $PROP" >&2; exit 1; }

ver="${cur_ver#v}"
IFS=. read -r MA MI PA <<<"$ver"
[[ "$MA" =~ ^[0-9]+$ && "$MI" =~ ^[0-9]+$ && "$PA" =~ ^[0-9]+$ ]] || { echo "unparseable version: $cur_ver" >&2; exit 1; }
new_ver="v${MA}.${MI}.$((PA + 1))"
new_code=$((cur_code + 1))

# Assemble the notes: the upstream summary lines, plus any extra lines passed in.
notes=""
[[ -s "$SUMMARY" ]] && notes=$(sed 's/^/- /' "$SUMMARY")
for extra in "$@"; do
    [[ -n "$extra" ]] && notes+=$'\n'"- $extra"
done
[[ -n "$notes" ]] || notes="- Maintenance and upstream refresh."

# Always list the exact upstream versions this release bundles, so a reader sees
# what's inside every build without digging — including the ones (TrickyStoreOSS,
# TEESimulator) that don't trigger a release on their own but ride along here.
pin() { sed -n "s/^$2=\"\{0,1\}//p" "$ROOT/$1" 2>/dev/null | head -1 | sed 's/"$//'; }
fork_pif=$(pin module-variants/fork/build.conf   PIF_TAG)
inj_pif=$( pin module-variants/inject/build.conf PIF_TAG)
tee_v=$(   pin build.sh TEE_TAG_DEFAULT)
tsoss_v=$( pin build.sh TSOSS_TAG_DEFAULT)
teesim_v=$(pin build.sh TEESIM_TAG_DEFAULT)
notes+=$'\n\n'"**Bundled in every build of this release**"
notes+=$'\n'"- Play Integrity: PlayIntegrityFork \`${fork_pif}\` (Fork builds) · PlayIntegrityFix inject-s \`${inj_pif}\` (inject builds)"
notes+=$'\n'"- Keystore: TEESimulator-RS \`${tee_v}\` (default) · TrickyStoreOSS \`${tsoss_v}\` (\`-TSOSS\`) · TEESimulator \`${teesim_v}\` (\`-TEESIM\`)"
notes+=$'\n'"- Not sure which file to grab? See **Which build to download** in the README."

# Bump module.prop
sed -i.bak \
    -e "s|^version=.*|version=${new_ver}|" \
    -e "s|^versionCode=.*|versionCode=${new_code}|" \
    "$PROP" && rm -f "$PROP.bak"

# Prepend a new "## <ver>" section right under the H1 heading.
tmp=$(mktemp)
{
    head -1 "$CHANGELOG"
    printf '\n## %s\n\n%s\n' "$new_ver" "$notes"
    tail -n +2 "$CHANGELOG"
} > "$tmp"
mv "$tmp" "$CHANGELOG"

echo "$new_ver"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "new_ver=$new_ver"   >> "$GITHUB_OUTPUT"
    echo "new_code=$new_code" >> "$GITHUB_OUTPUT"
fi
