#!/usr/bin/env bash
# AlwaysStrong build script.
# Downloads upstream TEESimulator-RS + PlayIntegrityFork release ZIPs,
# overlays our scripts, repackages into a single installable Magisk ZIP.
#
# Usage:
#   ./build.sh                  # build with defaults (latest pinned upstream versions)
#   ./build.sh --tee v6.0.0     # override TEESimulator-RS release tag
#   ./build.sh --pif v16        # override PlayIntegrityFork release tag
#   ./build.sh --tee-file PATH  # use a LOCAL TEESimulator-RS zip (e.g. a CI build) — skip download
#   ./build.sh --pif-file PATH  # use a LOCAL PlayIntegrityFork zip (e.g. a CI build) — skip download
#   ./build.sh --clean          # wipe build/ first
#
# CI / nightly builds live as GitHub Actions artifacts, not release assets, so
# fetch them yourself (e.g. `gh run download -R osm0sis/PlayIntegrityFork -D ci`)
# and point --pif-file / --tee-file at the resulting module zip.
#
# Requires: bash, curl OR wget, unzip, zip, sha256sum (or shasum on macOS).

set -euo pipefail

# ---------- Configurable upstream versions ----------
# Bump these when upstream cuts a new release.
# Find latest via: https://api.github.com/repos/<owner>/<repo>/releases/latest
TEE_TAG_DEFAULT="v6.0.1-282"
TEE_ASSET_DEFAULT="TEESimulator-RS-v6.0.1-282-Release.zip"
PIF_TAG_DEFAULT="v17"
PIF_ASSET_DEFAULT="PlayIntegrityFork-v17.zip"

TEE_TAG="$TEE_TAG_DEFAULT"
TEE_ASSET="$TEE_ASSET_DEFAULT"
PIF_TAG="$PIF_TAG_DEFAULT"
PIF_ASSET="$PIF_ASSET_DEFAULT"
DO_CLEAN=0
TEE_FILE=""
PIF_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tee)        TEE_TAG="$2"; shift 2 ;;
        --tee-asset)  TEE_ASSET="$2"; shift 2 ;;
        --pif)        PIF_TAG="$2"; shift 2 ;;
        --pif-asset)  PIF_ASSET="$2"; shift 2 ;;
        --tee-file)   TEE_FILE="$2"; shift 2 ;;
        --pif-file)   PIF_FILE="$2"; shift 2 ;;
        --clean)      DO_CLEAN=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0"
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ---------- Paths ----------
ROOT="$(cd "$(dirname "$0")" && pwd)"
MODULE_SRC="$ROOT/module"
BUILD="$ROOT/build"
STAGE="$BUILD/stage"
DL="$BUILD/downloads"
OUT="$ROOT/out"

# ---------- Color helpers ----------
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
die()    { red "ERROR: $*"; exit 1; }

# ---------- Tool checks ----------
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need unzip
need zip
if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fL --retry 3 --connect-timeout 15 -o"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -q -O"
else
    die "need curl or wget"
fi
if command -v sha256sum >/dev/null 2>&1; then
    SHA="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA="shasum -a 256"
else
    yellow "warning: no sha256sum/shasum — skipping hash verification"
    SHA=""
fi

# ---------- Clean ----------
if [[ $DO_CLEAN -eq 1 ]]; then
    bold "==> Cleaning build/"
    rm -rf "$BUILD"
fi

mkdir -p "$STAGE" "$DL" "$OUT"

# ---------- Download ----------
tee_zip="$DL/$TEE_ASSET"
pif_zip="$DL/$PIF_ASSET"

if [[ -n "$TEE_FILE" ]]; then
    [[ -f "$TEE_FILE" ]] || die "--tee-file not found: $TEE_FILE"
    tee_zip="$TEE_FILE"
    green "    local TEE zip: $TEE_FILE"
elif [[ ! -f "$tee_zip" ]]; then
    bold "==> Downloading TEESimulator-RS $TEE_TAG"
    $FETCH "$tee_zip" "https://github.com/Enginex0/TEESimulator-RS/releases/download/$TEE_TAG/$TEE_ASSET" \
        || die "TEESimulator-RS download failed"
else
    green "    cached: $TEE_ASSET"
fi

if [[ -n "$PIF_FILE" ]]; then
    [[ -f "$PIF_FILE" ]] || die "--pif-file not found: $PIF_FILE"
    pif_zip="$PIF_FILE"
    green "    local PIF zip: $PIF_FILE"
elif [[ ! -f "$pif_zip" ]]; then
    bold "==> Downloading PlayIntegrityFork $PIF_TAG"
    $FETCH "$pif_zip" "https://github.com/osm0sis/PlayIntegrityFork/releases/download/$PIF_TAG/$PIF_ASSET" \
        || die "PlayIntegrityFork download failed"
else
    green "    cached: $PIF_ASSET"
fi

# NOTE: the KSU WebUI Standalone APK is intentionally NOT bundled. On Magisk /
# APatch the module downloads it fresh from GitHub on the first [Action] press
# (see action.sh) — keeps the package small and always pulls the latest build.

# ---------- Native watcher (Rust, cross-compiled via cargo-ndk) ----------
# Compiles native/watcher/ into prebuilt/<abi>/aswatcher whenever source is
# newer than the binaries (or any binary is missing). Requires Rust + the
# four android targets + cargo-ndk + an Android NDK. If sources are unchanged
# and all four prebuilts exist, we skip — keeps incremental builds fast.

WATCHER_SRC_DIR="$ROOT/native/watcher"
WATCHER_PREBUILT="$WATCHER_SRC_DIR/prebuilt"
WATCHER_ABIS=(arm64-v8a armeabi-v7a x86 x86_64)

watcher_needs_build() {
    [[ -d "$WATCHER_SRC_DIR" ]] || return 1
    for abi in "${WATCHER_ABIS[@]}"; do
        [[ -f "$WATCHER_PREBUILT/$abi/aswatcher" ]] || return 0
    done
    # source newer than any prebuilt binary?
    local newest_src oldest_bin
    newest_src=$(find "$WATCHER_SRC_DIR/src" "$WATCHER_SRC_DIR/Cargo.toml" \
                     -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    oldest_bin=$(find "$WATCHER_PREBUILT" -name aswatcher \
                     -printf '%T@\n' 2>/dev/null | sort -n | head -1)
    [[ -z "$newest_src" || -z "$oldest_bin" ]] && return 0
    awk -v s="$newest_src" -v b="$oldest_bin" 'BEGIN{exit !(s>b)}'
}

# Resolve ANDROID_NDK_HOME from common locations if not exported.
find_ndk() {
    [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]] && return 0
    local cands=()
    [[ -n "${ANDROID_HOME:-}"      ]] && cands+=("$ANDROID_HOME/ndk")
    [[ -n "${ANDROID_SDK_ROOT:-}"  ]] && cands+=("$ANDROID_SDK_ROOT/ndk")
    cands+=( "$HOME/Android/Sdk/ndk" "/opt/android-ndk" )
    # WSL: pick up the Windows-side Android Studio install
    for u in /mnt/c/Users/*/AppData/Local/Android/Sdk/ndk; do
        [[ -d "$u" ]] && cands+=("$u")
    done
    for base in "${cands[@]}"; do
        [[ -d "$base" ]] || continue
        # use the highest-versioned NDK in that dir
        local pick
        pick=$(ls -1 "$base" 2>/dev/null | sort -V | tail -1)
        if [[ -n "$pick" && -d "$base/$pick/toolchains/llvm/prebuilt" ]]; then
            export ANDROID_NDK_HOME="$base/$pick"
            return 0
        fi
    done
    return 1
}

if watcher_needs_build; then
    bold "==> Building native watcher (Rust, 4 ABIs)"
    if ! command -v cargo >/dev/null 2>&1 && [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
    if ! command -v cargo >/dev/null 2>&1; then
        die "cargo not found. Install Rust: https://rustup.rs (then: rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android)"
    fi
    if ! command -v cargo-ndk >/dev/null 2>&1; then
        die "cargo-ndk not found. Install: cargo install cargo-ndk"
    fi
    if ! find_ndk; then
        die "Android NDK not found. Set ANDROID_NDK_HOME or install via Android Studio (SDK Manager -> NDK)"
    fi
    green "    NDK: $ANDROID_NDK_HOME"
    bash "$ROOT/scripts/build-watcher.sh"
else
    green "    cached: native watcher (4 ABIs in $WATCHER_PREBUILT)"
fi

# ---------- Native fetcher (Rust + rustls, cross-compiled via cargo-ndk) -----
# Same toolchain as the watcher. asfetch gives keybox_fetch/status a real TLS
# stack so downloads work on every device — busybox wget's built-in TLS stalls
# mid-stream on some CDNs (the keybox mirror included) on curl-less devices.
ASFETCH_SRC_DIR="$ROOT/native/asfetch"
ASFETCH_PREBUILT="$ASFETCH_SRC_DIR/prebuilt"
# arm only — asfetch matters on real devices (no curl, busybox TLS stalls).
# x86/x86_64 are emulator-only; there curl/busybox already work, and shipping
# rustls for them would add ~1.9 MB to the zip for no real-device benefit.
ASFETCH_ABIS=(arm64-v8a armeabi-v7a)

asfetch_needs_build() {
    [[ -d "$ASFETCH_SRC_DIR" ]] || return 1
    for abi in "${ASFETCH_ABIS[@]}"; do
        [[ -f "$ASFETCH_PREBUILT/$abi/asfetch" ]] || return 0
    done
    local newest_src oldest_bin
    newest_src=$(find "$ASFETCH_SRC_DIR/src" "$ASFETCH_SRC_DIR/Cargo.toml" \
                     -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    oldest_bin=$(find "$ASFETCH_PREBUILT" -name asfetch \
                     -printf '%T@\n' 2>/dev/null | sort -n | head -1)
    [[ -z "$newest_src" || -z "$oldest_bin" ]] && return 0
    awk -v s="$newest_src" -v b="$oldest_bin" 'BEGIN{exit !(s>b)}'
}

if asfetch_needs_build; then
    bold "==> Building native fetcher (Rust + rustls, 4 ABIs)"
    if ! command -v cargo >/dev/null 2>&1 && [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
    command -v cargo    >/dev/null 2>&1 || die "cargo not found. Install Rust: https://rustup.rs"
    command -v cargo-ndk >/dev/null 2>&1 || die "cargo-ndk not found. Install: cargo install cargo-ndk"
    find_ndk || die "Android NDK not found. Set ANDROID_NDK_HOME or install via Android Studio (SDK Manager -> NDK)"
    green "    NDK: $ANDROID_NDK_HOME"
    bash "$ROOT/scripts/build-asfetch.sh"
else
    green "    cached: native fetcher (4 ABIs in $ASFETCH_PREBUILT)"
fi

# ---------- Stage layout ----------
bold "==> Staging module files"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# 1) Our scripts/configs (the glue). These override anything from upstream.
cp -a "$MODULE_SRC/." "$STAGE/"

# 1b) Ship banner.png inside the module so the manager shows it locally
#     (module.prop: banner=/data/adb/modules/tricky_store/banner.png) instead of
#     hot-linking raw.githubusercontent.com. customize.sh extracts it on install.
if [[ -f "$ROOT/banner.png" ]]; then
    cp "$ROOT/banner.png" "$STAGE/banner.png"
    green "    bundled banner.png ($(du -h "$ROOT/banner.png" | cut -f1))"
else
    yellow "    warning: banner.png not found at repo root — module banner will be missing"
fi

# 2) Extract TEESimulator-RS binaries. We take:
#      - lib/<abi>/lib*.so (all four arches)
#      - classes.dex (renamed to tee_classes.dex to coexist with PIF's classes.dex)
#      - keybox.xml (default AOSP, only used if user has none)
#    We do NOT take its customize.sh/service.sh/post-fs-data.sh/action.sh — ours replace them.
TEE_EXTRACT="$BUILD/tee_extracted"
rm -rf "$TEE_EXTRACT"
mkdir -p "$TEE_EXTRACT"
unzip -qq -o "$tee_zip" -d "$TEE_EXTRACT"

mkdir -p "$STAGE/lib"
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    if [[ -d "$TEE_EXTRACT/lib/$abi" ]]; then
        mkdir -p "$STAGE/lib/$abi"
        cp "$TEE_EXTRACT/lib/$abi"/*.so "$STAGE/lib/$abi/"
    fi
done

[[ -f "$TEE_EXTRACT/classes.dex" ]] || die "TEESimulator ZIP missing classes.dex"
cp "$TEE_EXTRACT/classes.dex" "$STAGE/tee_classes.dex"

[[ -f "$TEE_EXTRACT/keybox.xml" ]] && cp "$TEE_EXTRACT/keybox.xml" "$STAGE/keybox.xml"

# 3) Extract PlayIntegrityFork: zygisk libs, classes.dex (PIF's, stays as classes.dex),
#    autopif4.sh/killpi.sh/migrate.sh (refresh tooling), example.pif.prop/app_replace_list.txt,
#    common_setup.sh.
PIF_EXTRACT="$BUILD/pif_extracted"
rm -rf "$PIF_EXTRACT"
mkdir -p "$PIF_EXTRACT"
unzip -qq -o "$pif_zip" -d "$PIF_EXTRACT"

mkdir -p "$STAGE/zygisk"
cp "$PIF_EXTRACT/zygisk"/*.so "$STAGE/zygisk/" 2>/dev/null || die "PIF zygisk libs missing"

[[ -f "$PIF_EXTRACT/classes.dex" ]] || die "PIF ZIP missing classes.dex"
cp "$PIF_EXTRACT/classes.dex" "$STAGE/classes.dex"

for f in autopif4.sh killpi.sh migrate.sh common_setup.sh example.pif.prop app_replace_list.txt; do
    if [[ -f "$PIF_EXTRACT/$f" ]]; then
        cp "$PIF_EXTRACT/$f" "$STAGE/$f"
    fi
done

# 4) Stage the Rust watcher + fetcher binaries (built/cached above).
mkdir -p "$STAGE/bin"
for abi in "${WATCHER_ABIS[@]}"; do
    src="$WATCHER_PREBUILT/$abi/aswatcher"
    [[ -f "$src" ]] || die "aswatcher binary missing for $abi (build step failed?)"
    mkdir -p "$STAGE/bin/$abi"
    cp "$src" "$STAGE/bin/$abi/aswatcher"
    chmod 755 "$STAGE/bin/$abi/aswatcher"
done
for abi in "${ASFETCH_ABIS[@]}"; do
    src="$ASFETCH_PREBUILT/$abi/asfetch"
    [[ -f "$src" ]] || die "asfetch binary missing for $abi (build step failed?)"
    mkdir -p "$STAGE/bin/$abi"
    cp "$src" "$STAGE/bin/$abi/asfetch"
    chmod 755 "$STAGE/bin/$abi/asfetch"
done

# 5) Rewrite hard-coded /data/adb/modules/playintegrityfix references in PIF scripts
#    to our module id (tricky_store). Done in-place on copies inside the stage.
bold "==> Patching PIF script paths -> /data/adb/modules/tricky_store"
for f in "$STAGE/autopif4.sh" "$STAGE/killpi.sh" "$STAGE/migrate.sh" "$STAGE/common_setup.sh"; do
    [[ -f "$f" ]] || continue
    # Linux/macOS sed compat
    if sed --version >/dev/null 2>&1; then
        SED_I=(sed -i)
    else
        SED_I=(sed -i '')
    fi
    "${SED_I[@]}" 's|/data/adb/modules/playintegrityfix|/data/adb/modules/tricky_store|g' "$f"
done

# Bound autopif4's wget calls so a hung IPv6 connect doesn't stall the whole
# bootstrap. Use the short -T (timeout, seconds) option ONLY: it's the single
# flag that toybox wget, busybox wget AND GNU wget all accept. The long forms
# (--timeout / --tries) are NOT in toybox wget, and --tries isn't in busybox
# wget either — injecting them makes every fetch error out with "unknown
# option" and the fingerprint refresh silently fails.
if [[ -f "$STAGE/autopif4.sh" ]]; then
    bold "==> Patching autopif4.sh: wget -T 10"
    "${SED_I[@]}" 's|wget -q |wget -q -T 10 |g' "$STAGE/autopif4.sh"

    # autopif4 only falls back to busybox wget when the system wget is missing
    # or is the wget-curl shim. On a Pixel the toybox wget exists but lacks the
    # --no-check-certificate / --header / --spider options autopif4 relies on,
    # so the crawl dies. Magisk/KSU/APatch always ship a busybox that supports
    # all of them — prefer it whenever present.
    bold "==> Patching autopif4.sh: prefer busybox wget"
    perl -0777 -pi -e 's{if ! which wget >/dev/null \|\| grep -q "wget-curl" \$\(which wget\); then}{if find_busybox; then wget() { \$BUSYBOX wget "\$\@"; }; elif ! which wget >/dev/null || grep -q "wget-curl" \$(which wget); then}' "$STAGE/autopif4.sh" \
        && grep -q 'if find_busybox; then wget()' "$STAGE/autopif4.sh" \
        && green "    busybox-wget preference applied" \
        || yellow "    warning: could not apply busybox-wget preference (autopif4 layout changed?)"
fi

# 5b) Binary-patch the PIF zygisk .so libraries so they read classes.dex and
#     pif config from OUR module dir (/data/adb/modules/tricky_store) instead
#     of the upstream-hardcoded /data/adb/modules/playintegrityfix. This is
#     what lets us drop the old symlink-shim that created a stray
#     playintegrityfix folder under /data/adb/modules.
#
#     Length-preserving + filename-agnostic: we only rewrite the directory
#     prefix, padding the freed bytes with extra '/' (collapsed by the kernel)
#     or NUL (truncates the C string at the right spot). The trailing filename
#     ("/classes.dex", "/pif.json", …) is left untouched.
#       "/data/adb/modules/playintegrityfix/" (35B) -> ".../tricky_store/////" (35B)
#       "/data/adb/modules/playintegrityfix\0" (35B) -> ".../tricky_store\0\0\0\0\0" (35B)
bold "==> Binary-patching PIF zygisk path -> /data/adb/modules/tricky_store"
if command -v perl >/dev/null 2>&1; then
    SO_PATCH() {
        perl -0777 -pi -e '
            s{/data/adb/modules/playintegrityfix/}{/data/adb/modules/tricky_store/////}g;
            s{/data/adb/modules/playintegrityfix\x00}{/data/adb/modules/tricky_store\x00\x00\x00\x00\x00}g;
        ' "$1"
    }
elif command -v python3 >/dev/null 2>&1; then
    SO_PATCH() {
        python3 - "$1" <<'PY'
import sys
p=sys.argv[1]
d=open(p,'rb').read()
d=d.replace(b'/data/adb/modules/playintegrityfix/', b'/data/adb/modules/tricky_store/////')
d=d.replace(b'/data/adb/modules/playintegrityfix\x00', b'/data/adb/modules/tricky_store\x00\x00\x00\x00\x00')
open(p,'wb').write(d)
PY
    }
else
    die "need perl or python3 to binary-patch the PIF zygisk libraries"
fi
for so in "$STAGE/zygisk"/*.so; do
    [[ -f "$so" ]] || continue
    SO_PATCH "$so"
    new_refs=$(grep -ac "modules/tricky_store" "$so" 2>/dev/null) || new_refs=0
    green "    $(basename "$so"): tricky_store path refs=$new_refs"
done

# --- Hard guard: ONE module, never a stray playintegrityfix folder ---------
# After patching, NO shipped .so or PIF helper script may point at any
# /data/adb/modules/<name> other than tricky_store. If a future upstream bump
# renames or restructures PIF's hardcoded path, the byte-patch / sed silently
# misses it and PIF would recreate its own module folder under
# /data/adb/modules — exactly what we forbid. Fail the build loudly instead of
# shipping that, so an incompatible bump can never slip through unnoticed.
bold "==> Verifying PIF stays inside tricky_store (no stray module folder)"
for so in "$STAGE/zygisk"/*.so; do
    [[ -f "$so" ]] || continue
    stray=$(grep -aoE '/data/adb/modules/[A-Za-z0-9_.-]+' "$so" 2>/dev/null \
            | grep -vxF '/data/adb/modules/tricky_store' | sort -u || true)
    if [[ -n "$stray" ]]; then
        red "    $(basename "$so") references a foreign module path:"
        printf '      %s\n' $stray
        die "zygisk byte-patch incomplete — upstream changed PIF's hardcoded path. Update SO_PATCH in build.sh before shipping."
    fi
done
for f in autopif4.sh killpi.sh migrate.sh common_setup.sh; do
    [[ -f "$STAGE/$f" ]] || continue
    if grep -qF 'modules/playintegrityfix' "$STAGE/$f"; then
        die "$f still references modules/playintegrityfix after sed patch — upstream layout changed; fix the path patch in build.sh."
    fi
done
green "    ok — PIF reads only /data/adb/modules/tricky_store"

# 6) Normalize line endings on every shell/text script that ships to the device.
#    Android /system/bin/sh treats `\r` as part of arguments — a CRLF customize.sh
#    fails with cryptic "no such file" errors. Strip CR from anything text-like.
bold "==> Normalizing line endings (LF) on shipped scripts"
for f in "$STAGE"/*.sh "$STAGE/daemon" "$STAGE/module.prop" "$STAGE/target.txt" \
         "$STAGE/sepolicy.rule" \
         "$STAGE/META-INF/com/google/android/update-binary" \
         "$STAGE/META-INF/com/google/android/updater-script"; do
    [ -f "$f" ] && sed -i 's/\r$//' "$f"
done

# 7) Ensure executable bits on shell scripts, TEE daemon, native binaries
chmod 755 "$STAGE/daemon" "$STAGE"/*.sh 2>/dev/null || true
for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    [[ -f "$STAGE/bin/$abi/aswatcher" ]] && chmod 755 "$STAGE/bin/$abi/aswatcher"
    [[ -f "$STAGE/bin/$abi/asfetch" ]]   && chmod 755 "$STAGE/bin/$abi/asfetch"
done

# Note: webroot/ (KSU/APatch/MMRL WebUI) gets staged automatically by step 1's
# cp -a — no extra step needed. KSU/APatch detect the dir at runtime and
# show an "Open Web UI" entry next to the module.

# ---------- Generate ZIP ----------
VERSION=$(grep '^version=' "$STAGE/module.prop" | cut -d= -f2)
OUT_ZIP="$OUT/AlwaysStrong-${VERSION}.zip"
rm -f "$OUT_ZIP"

bold "==> Packaging $OUT_ZIP"
( cd "$STAGE" && zip -qr "$OUT_ZIP" . -x "*.DS_Store" )

# ---------- Summary ----------
SIZE=$(du -h "$OUT_ZIP" | cut -f1)
green ""
green "  Built: $(basename "$OUT_ZIP")  ($SIZE)"
green "  Path:  $OUT_ZIP"
if [[ -n "$SHA" ]]; then
    HASH=$($SHA "$OUT_ZIP" | awk '{print $1}')
    green "  SHA256: $HASH"
fi
green ""
