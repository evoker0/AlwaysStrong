#!/usr/bin/env bash
# AlwaysStrong build script.
# Downloads the upstream TEESimulator-RS + Play Integrity release ZIPs, overlays
# our scripts, and repackages each release line into an installable Magisk ZIP.
#
# module/ holds everything the two lines share; module-variants/<line>/ holds
# what differs:
#
#   module-variants/<line>/build.conf            upstream pin + which files to lift
#   module-variants/<line>/module.prop.override  module.prop keys to rewrite
#   module-variants/<line>/ship/                 files overlaid into the module
#
# Two orthogonal axes:
#   --variant  fork | inject | nopif          the Play Integrity line
#   --engine   tee | trickystoreoss | teesim  the attestation backend (keystore).
#                                   Default tee. tee/trickystoreoss read
#                                   /data/adb/tricky_store/; teesim uses its own
#                                   /data/adb/teesim/config.json (bridged for it).
#
# Attestation engines:
#   tee             TEESimulator-RS, Enginex0 (Rust port; leaf-hack works for every app)
#   trickystoreoss  TrickyStoreOSS, beakthoven (open source; classes.dex + libinject.so)
#   teesim          TEESimulator, JingMatrix (the original; Kotlin daemon + KeyMint
#                   interceptor; 64-bit only; -TEESIM suffix)
#
# Usage:
#   ./build.sh                              # all lines, TEESimulator-RS engine
#   ./build.sh --variant fork               # only the default (PlayIntegrityFork) line
#   ./build.sh --variant inject             # only the PlayIntegrityFix inject-s line
#   ./build.sh --variant nopif              # only the PIF-less Lite line
#   ./build.sh --engine trickystoreoss      # all lines, TrickyStoreOSS engine (-TSOSS)
#   ./build.sh --engine teesim              # all lines, TEESimulator/JingMatrix (-TEESIM)
#   ./build.sh --tee v6.0.0                 # override the TEESimulator-RS release tag
#   ./build.sh --tee-file PATH              # use a LOCAL TEESimulator-RS zip, skip the download
#   ./build.sh --tsoss v3.0.0               # override the TrickyStoreOSS release tag
#   ./build.sh --tsoss-file PATH            # use a LOCAL TrickyStoreOSS zip, skip the download
#   ./build.sh --teesim canary-63           # override the TEESimulator (JingMatrix) tag
#   ./build.sh --teesim-file PATH           # use a LOCAL TEESimulator (JingMatrix) zip
#   ./build.sh --pif v16                    # override the PIF tag  (needs --variant)
#   ./build.sh --pif-file PATH              # use a LOCAL PIF zip   (needs --variant)
#   ./build.sh --clean                      # wipe build/ first
#
# Output (-TSOSS = TrickyStoreOSS, -TEESIM = TEESimulator/JingMatrix; plain = RS):
#   out/AlwaysStrong-<ver>.zip               PlayIntegrityFork          + TEESimulator-RS
#   out/AlwaysStrong-<ver>-inject.zip        PlayIntegrityFix inject-s  + TEESimulator-RS
#   out/AlwaysStrong-<ver>-nopif.zip         PIF-less / Lite            + TEESimulator-RS
#   out/AlwaysStrong-<ver>-TSOSS.zip         PlayIntegrityFork          + TrickyStoreOSS
#   out/AlwaysStrong-<ver>-inject-TSOSS.zip  PlayIntegrityFix inject-s  + TrickyStoreOSS
#   out/AlwaysStrong-<ver>-nopif-TSOSS.zip   PIF-less / Lite            + TrickyStoreOSS
#   out/AlwaysStrong-<ver>-TEESIM.zip        PlayIntegrityFork          + TEESimulator (JingMatrix)
#   out/AlwaysStrong-<ver>-inject-TEESIM.zip PlayIntegrityFix inject-s  + TEESimulator (JingMatrix)
#   out/AlwaysStrong-<ver>-nopif-TEESIM.zip  PIF-less / Lite            + TEESimulator (JingMatrix)
#
# CI / nightly builds live as GitHub Actions artifacts, not release assets, so
# fetch them yourself (e.g. `gh run download -R osm0sis/PlayIntegrityFork -D ci`)
# and point --pif-file / --tee-file / --tsoss-file at the resulting module zip.
#
# Requires: bash, curl OR wget, unzip, zip, sha256sum (or shasum on macOS).

set -euo pipefail

# ---------- Configurable upstream versions ----------
# TEESimulator-RS is shared by both lines and pinned here. Each line's Play
# Integrity engine is pinned in its own module-variants/<line>/build.conf.
# Bump with: scripts/update-upstream.sh --apply
TEE_TAG_DEFAULT="v6.0.1-307"
TEE_ASSET_DEFAULT="TEESimulator-RS-v6.0.1-307-Release.zip"

# TrickyStoreOSS (beakthoven) — the open-source TrickyStore keystore engine
# (plain classes.dex + libinject.so, no obfuscated blobs). Only used when
# --engine trickystoreoss is passed. Pinned here; --tsoss / --tsoss-file override.
TSOSS_TAG_DEFAULT="v3.1.0"
TSOSS_ASSET_DEFAULT="Tricky-Store-OSS-v3.1.0-172-41383f5-Release.zip"

# TEESimulator (JingMatrix) — the ORIGINAL TEESimulator: a Kotlin control daemon
# (app_process) plus a native keymint/keystore interceptor injected into
# keystore2. It uses its own /data/adb/teesim/config.json layout, so attest/
# teesim.sh bridges the AlwaysStrong keybox + target list into it. Only used with
# --engine teesim. Pinned here; --teesim / --teesim-file override. 64-bit only.
TEESIM_TAG_DEFAULT="canary-63"
TEESIM_ASSET_DEFAULT="TEESimulator-v4.0-63-123d8ba-Release.zip"

TEE_TAG="$TEE_TAG_DEFAULT"
TEE_ASSET="$TEE_ASSET_DEFAULT"
TSOSS_TAG="$TSOSS_TAG_DEFAULT"
TSOSS_ASSET="$TSOSS_ASSET_DEFAULT"
TEESIM_TAG="$TEESIM_TAG_DEFAULT"
TEESIM_ASSET="$TEESIM_ASSET_DEFAULT"
ENGINE_KIND="tee"          # tee (default) | trickystoreoss | teesim
DO_CLEAN=0
TEE_FILE=""
TSOSS_FILE=""
TEESIM_FILE=""
PIF_FILE=""
PIF_TAG_OVERRIDE=""
PIF_ASSET_OVERRIDE=""
VARIANTS_REQUESTED=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tee)        TEE_TAG="$2"; shift 2 ;;
        --tee-asset)  TEE_ASSET="$2"; shift 2 ;;
        --tsoss)      TSOSS_TAG="$2"; shift 2 ;;
        --tsoss-asset) TSOSS_ASSET="$2"; shift 2 ;;
        --tsoss-file) TSOSS_FILE="$2"; shift 2 ;;
        --teesim)     TEESIM_TAG="$2"; shift 2 ;;
        --teesim-asset) TEESIM_ASSET="$2"; shift 2 ;;
        --teesim-file) TEESIM_FILE="$2"; shift 2 ;;
        --engine)     ENGINE_KIND="$2"; shift 2 ;;
        --pif)        PIF_TAG_OVERRIDE="$2"; shift 2 ;;
        --pif-asset)  PIF_ASSET_OVERRIDE="$2"; shift 2 ;;
        --tee-file)   TEE_FILE="$2"; shift 2 ;;
        --pif-file)   PIF_FILE="$2"; shift 2 ;;
        --clean)      DO_CLEAN=1; shift ;;
        --variant)    VARIANTS_REQUESTED="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0"
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# A CR inside a pin makes the download URL "…/v6.0.1-307<CR>/…", which curl
# rejects as malformed. Invisible in the log — a CR just returns the cursor.
strip_cr() { printf '%s' "${1//$'\r'/}"; }
TEE_TAG=$(strip_cr "$TEE_TAG")
TEE_ASSET=$(strip_cr "$TEE_ASSET")
TSOSS_TAG=$(strip_cr "$TSOSS_TAG")
TSOSS_ASSET=$(strip_cr "$TSOSS_ASSET")
TEESIM_TAG=$(strip_cr "$TEESIM_TAG")
TEESIM_ASSET=$(strip_cr "$TEESIM_ASSET")
ENGINE_KIND=$(strip_cr "$ENGINE_KIND")

case "$ENGINE_KIND" in
    tee|trickystoreoss|teesim) ;;
    *) echo "Unknown --engine '$ENGINE_KIND' (use: tee | trickystoreoss | teesim)" >&2; exit 1 ;;
esac

# ---------- Paths ----------
ROOT="$(cd "$(dirname "$0")" && pwd)"
MODULE_SRC="$ROOT/module"
VARIANT_SRC="$ROOT/module-variants"
ATTEST_SRC="$ROOT/attest"
BUILD="$ROOT/build"
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

mkdir -p "$DL" "$OUT"

# ---------- Which release lines to build ----------
ALL_VARIANTS=()
for d in "$VARIANT_SRC"/*/; do
    [[ -f "$d/build.conf" ]] && ALL_VARIANTS+=("$(basename "$d")")
done
[[ ${#ALL_VARIANTS[@]} -gt 0 ]] || die "no build lines found under module-variants/"

if [[ -n "$VARIANTS_REQUESTED" ]]; then
    IFS=',' read -r -a VARIANTS <<< "$VARIANTS_REQUESTED"
    for v in "${VARIANTS[@]}"; do
        [[ -f "$VARIANT_SRC/$v/build.conf" ]] \
            || die "unknown --variant '$v' (have: ${ALL_VARIANTS[*]})"
    done
else
    VARIANTS=("${ALL_VARIANTS[@]}")
fi

# --pif / --pif-file name ONE engine, so they only make sense for one line.
if [[ ${#VARIANTS[@]} -gt 1 ]] \
   && [[ -n "$PIF_FILE$PIF_TAG_OVERRIDE$PIF_ASSET_OVERRIDE" ]]; then
    die "--pif/--pif-asset/--pif-file apply to a single line — add --variant fork|inject"
fi

# ---------- zip (or a 7-Zip stand-in) ----------
# Git-Bash / MSYS boxes ship 7-Zip but no Info-ZIP `zip`. Rather than fail at
# the packaging step, drop a shim on PATH.
if ! command -v zip >/dev/null 2>&1; then
    SEVENZ=""
    for c in 7z 7za "/c/Program Files/7-Zip/7z.exe" "/c/Program Files (x86)/7-Zip/7z.exe"; do
        if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then SEVENZ="$c"; break; fi
    done
    [[ -n "$SEVENZ" ]] || die "missing required tool: zip (install Info-ZIP, or 7-Zip and re-run)"
    mkdir -p "$BUILD/shim"
    cat > "$BUILD/shim/zip" <<EOF
#!/usr/bin/env bash
# Info-ZIP stand-in backed by 7-Zip. Covers exactly what build.sh calls:
#   zip -qr <out.zip> <path...> [-x <pattern>...]
set -euo pipefail
out=""; paths=()
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        -x) shift 2 ;;
        -*) shift ;;
        *)  if [[ -z "\$out" ]]; then out="\$1"; else paths+=("\$1"); fi; shift ;;
    esac
done
[[ -n "\$out" ]] || { echo "zip-shim: no output file" >&2; exit 1; }
command -v cygpath >/dev/null 2>&1 && out="\$(cygpath -w "\$out")"
exec "$SEVENZ" a -tzip -bso0 -bsp0 "-xr!.DS_Store" "\$out" "\${paths[@]}"
EOF
    chmod 755 "$BUILD/shim/zip"
    export PATH="$BUILD/shim:$PATH"
    yellow "    zip not found — packaging with 7-Zip ($SEVENZ)"
fi

# ---------- Download the shared attestation engine ----------
# Exactly one engine is fetched per run, selected by --engine. Both are shared
# across every requested line, so this happens once, before build_variant.
tee_zip=""
tsoss_zip=""
teesim_zip=""

case "$ENGINE_KIND" in
tee)
    [[ -f "$ATTEST_SRC/tee.sh" ]] || die "missing attest/tee.sh"
    tee_zip="$DL/$TEE_ASSET"
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
    ;;
trickystoreoss)
    [[ -f "$ATTEST_SRC/trickystoreoss.sh" ]] || die "missing attest/trickystoreoss.sh"
    tsoss_zip="$DL/$TSOSS_ASSET"
    if [[ -n "$TSOSS_FILE" ]]; then
        [[ -f "$TSOSS_FILE" ]] || die "--tsoss-file not found: $TSOSS_FILE"
        tsoss_zip="$TSOSS_FILE"
        green "    local TrickyStoreOSS zip: $TSOSS_FILE"
    elif [[ ! -f "$tsoss_zip" ]]; then
        bold "==> Downloading TrickyStoreOSS $TSOSS_TAG"
        $FETCH "$tsoss_zip" "https://github.com/beakthoven/TrickyStoreOSS/releases/download/$TSOSS_TAG/$TSOSS_ASSET" \
            || die "TrickyStoreOSS download failed"
    else
        green "    cached: $TSOSS_ASSET"
    fi
    ;;
teesim)
    [[ -f "$ATTEST_SRC/teesim.sh" ]] || die "missing attest/teesim.sh"
    teesim_zip="$DL/$TEESIM_ASSET"
    if [[ -n "$TEESIM_FILE" ]]; then
        [[ -f "$TEESIM_FILE" ]] || die "--teesim-file not found: $TEESIM_FILE"
        teesim_zip="$TEESIM_FILE"
        green "    local TEESimulator (JingMatrix) zip: $TEESIM_FILE"
    elif [[ ! -f "$teesim_zip" ]]; then
        bold "==> Downloading TEESimulator (JingMatrix) $TEESIM_TAG"
        $FETCH "$teesim_zip" "https://github.com/JingMatrix/TEESimulator/releases/download/$TEESIM_TAG/$TEESIM_ASSET" \
            || die "TEESimulator (JingMatrix) download failed"
    else
        green "    cached: $TEESIM_ASSET"
    fi
    ;;
esac

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

# Every prebuilt present, but no Rust toolchain? Ship the committed binaries and
# say so, instead of failing the whole build. A git checkout rewrites mtimes, so
# "sources are newer" is usually just checkout order, not an actual code change.
have_all_prebuilts() {
    local dir="$1" name="$2"; shift 2
    local abi
    for abi in "$@"; do [[ -f "$dir/$abi/$name" ]] || return 1; done
    return 0
}
toolchain_ready() {
    if ! command -v cargo >/dev/null 2>&1 && [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
    command -v cargo >/dev/null 2>&1 && command -v cargo-ndk >/dev/null 2>&1 && find_ndk
}

if watcher_needs_build && ! toolchain_ready \
   && have_all_prebuilts "$WATCHER_PREBUILT" aswatcher "${WATCHER_ABIS[@]}"; then
    yellow "    no Rust/NDK toolchain — shipping the committed aswatcher prebuilts"
elif watcher_needs_build; then
    bold "==> Building native watcher (Rust, 4 ABIs)"
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

if asfetch_needs_build && ! toolchain_ready \
   && have_all_prebuilts "$ASFETCH_PREBUILT" asfetch "${ASFETCH_ABIS[@]}"; then
    yellow "    no Rust/NDK toolchain — shipping the committed asfetch prebuilts"
elif asfetch_needs_build; then
    bold "==> Building native fetcher (Rust + rustls, 4 ABIs)"
    command -v cargo    >/dev/null 2>&1 || die "cargo not found. Install Rust: https://rustup.rs"
    command -v cargo-ndk >/dev/null 2>&1 || die "cargo-ndk not found. Install: cargo install cargo-ndk"
    find_ndk || die "Android NDK not found. Set ANDROID_NDK_HOME or install via Android Studio (SDK Manager -> NDK)"
    green "    NDK: $ANDROID_NDK_HOME"
    bash "$ROOT/scripts/build-asfetch.sh"
else
    green "    cached: native fetcher (4 ABIs in $ASFETCH_PREBUILT)"
fi

# ---------- Build one release line ----------
# Runs once per line in $VARIANTS. The line supplies its upstream pin and file
# lists via build.conf; the module scripts it overlays live in its ship/.
BUILT_ZIPS=()

build_variant() {
  local VARIANT="$1"
  local VDIR="$VARIANT_SRC/$VARIANT"
  local STAGE="$BUILD/stage-$VARIANT"

  # reset first: a second line must not inherit the first one's settings
  local ZIP_SUFFIX="" PIF_REPO="" PIF_TAG="" PIF_ASSET="" PIF_ASSET_FILTER=""
  local PIF_FILES="" PIF_REQUIRED="" PIF_PATCH_PATHS=""
  local PATCH_AUTOPIF4_WGET=0 PIF_ANTITAMPER=0
  # PIF_NONE=1 -> a PIF-less "Lite" line: TEESimulator/TSOSS attestation + the
  # keybox fetcher only, no PlayIntegrityFork/Fix zygisk. For setups where the
  # bundled PIF conflicts with GMS. build.conf sets PIF_NONE=1 and no PIF pins.
  local PIF_NONE=0
  # Sourced through a CR-stripped copy: .gitattributes pins build.conf to LF,
  # but an editor or a tarball can still hand us CRLF.
  mkdir -p "$BUILD"
  tr -d '\r' < "$VDIR/build.conf" > "$BUILD/.build.conf.$VARIANT"
  # shellcheck source=/dev/null
  source "$BUILD/.build.conf.$VARIANT"
  rm -f "$BUILD/.build.conf.$VARIANT"
  [[ -n "$PIF_TAG_OVERRIDE"   ]] && PIF_TAG="$PIF_TAG_OVERRIDE"
  [[ -n "$PIF_ASSET_OVERRIDE" ]] && PIF_ASSET="$PIF_ASSET_OVERRIDE"
  if [[ "$PIF_NONE" != "1" ]]; then
      [[ -n "$PIF_REPO" && -n "$PIF_TAG" && -n "$PIF_ASSET" ]] \
          || die "$VARIANT: build.conf is missing PIF_REPO / PIF_TAG / PIF_ASSET"
  fi

  bold ""
  if [[ "$PIF_NONE" == "1" ]]; then
      bold "==> Building the '$VARIANT' line (PIF-less / Lite)"
  else
      bold "==> Building the '$VARIANT' line ($PIF_REPO $PIF_TAG)"
  fi

  # ---------- Download this line's Play Integrity engine ----------
  local pif_zip="$DL/$PIF_ASSET"
  if [[ "$PIF_NONE" == "1" ]]; then
      green "    PIF-less line — no Play Integrity engine to download"
  elif [[ -n "$PIF_FILE" ]]; then
      [[ -f "$PIF_FILE" ]] || die "--pif-file not found: $PIF_FILE"
      pif_zip="$PIF_FILE"
      green "    local PIF zip: $PIF_FILE"
  elif [[ ! -f "$pif_zip" ]]; then
      bold "==> Downloading $PIF_REPO $PIF_TAG"
      $FETCH "$pif_zip" "https://github.com/$PIF_REPO/releases/download/$PIF_TAG/$PIF_ASSET" \
          || die "$PIF_REPO download failed"
  else
      green "    cached: $PIF_ASSET"
  fi

# ---------- Stage layout ----------
bold "==> Staging module files"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# 1) Our scripts/configs (the glue). These override anything from upstream.
cp -a "$MODULE_SRC/." "$STAGE/"

# 1a) Overlay this line's own files (engine.sh, description.txt, ...) on top.
if [[ -d "$VDIR/ship" ]]; then
    cp -a "$VDIR/ship/." "$STAGE/"
    green "    overlaid module-variants/$VARIANT/ship/"
fi

# 1a2) Apply this line's module.prop overrides. version / versionCode are not
#      overridable: they stay defined once, in module/module.prop, so the two
#      lines can't drift apart on the number users see.
if [[ -f "$VDIR/module.prop.override" ]]; then
    # awk, not sed: the replacement is a description string, and in a sed
    # replacement `&` expands to the whole match and `\` escapes. awk takes the
    # line as a variable and never reinterprets it.
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        local k="${line%%=*}"
        case "$k" in
            version|versionCode|id)
                die "$VARIANT/module.prop.override may not override '$k'" ;;
        esac
        grep -q "^${k}=" "$STAGE/module.prop" \
            || die "$VARIANT/module.prop.override sets unknown key '$k'"
        awk -v key="$k=" -v repl="$line" \
            'index($0, key) == 1 { print repl; next } { print }' \
            "$STAGE/module.prop" > "$STAGE/module.prop.new" \
            && mv "$STAGE/module.prop.new" "$STAGE/module.prop"
    done < "$VDIR/module.prop.override"
    green "    applied module.prop overrides"
fi

# 1b) Ship banner.png inside the module so the manager shows it locally
#     (module.prop: banner=/data/adb/modules/tricky_store/banner.png) instead of
#     hot-linking raw.githubusercontent.com. customize.sh extracts it on install.
if [[ -f "$ROOT/banner.png" ]]; then
    cp "$ROOT/banner.png" "$STAGE/banner.png"
    green "    bundled banner.png ($(du -h "$ROOT/banner.png" | cut -f1))"
else
    yellow "    warning: banner.png not found at repo root — module banner will be missing"
fi

# 2) Extract the attestation engine payload into the stage. The per-engine
#    install/start steps live in attest/<engine>.sh (copied in as attest.sh
#    below); here we only lift the binaries each engine needs. We never take an
#    engine's own customize.sh/service.sh/post-fs-data.sh/action.sh — ours win.
if [[ "$ENGINE_KIND" == "tee" ]]; then
    # TEESimulator-RS: lib/<abi>/lib*.so (all four arches), classes.dex renamed
    # to tee_classes.dex (so it coexists with PIF's classes.dex), and a default
    # keybox.xml (only used when the user has none).
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
elif [[ "$ENGINE_KIND" == "trickystoreoss" ]]; then
    # TrickyStoreOSS (beakthoven): a plain classes.dex (renamed to
    # tsoss_classes.dex so it coexists with PIF's classes.dex), per-abi
    # libTrickyStoreOSS.so + libinject.so (Android abi names, all four arches),
    # and a default keybox. No obfuscated blobs, no .sha256 manifest. We ship a
    # daemon that app_process-launches tsoss_classes.dex's MainKt.
    TSOSS_EXTRACT="$BUILD/tsoss_extracted"
    rm -rf "$TSOSS_EXTRACT"
    mkdir -p "$TSOSS_EXTRACT"
    unzip -qq -o "$tsoss_zip" -d "$TSOSS_EXTRACT"

    mkdir -p "$STAGE/lib"
    for abi in arm64-v8a armeabi-v7a x86 x86_64; do
        if [[ -d "$TSOSS_EXTRACT/lib/$abi" ]]; then
            mkdir -p "$STAGE/lib/$abi"
            cp "$TSOSS_EXTRACT/lib/$abi"/*.so "$STAGE/lib/$abi/"
        fi
    done
    [[ -f "$STAGE/lib/arm64-v8a/libTrickyStoreOSS.so" ]] \
        || die "TrickyStoreOSS ZIP missing lib/arm64-v8a/libTrickyStoreOSS.so — upstream layout changed"
    [[ -f "$STAGE/lib/arm64-v8a/libinject.so" ]] \
        || die "TrickyStoreOSS ZIP missing lib/arm64-v8a/libinject.so — upstream layout changed"

    [[ -f "$TSOSS_EXTRACT/classes.dex" ]] || die "TrickyStoreOSS ZIP missing classes.dex"
    cp "$TSOSS_EXTRACT/classes.dex" "$STAGE/tsoss_classes.dex"

    # Our own daemon: load the renamed dex and run OSS's MainKt. Replaces the TEE
    # daemon script module/ ships. Takes $MODDIR as $1 (attest_start passes it).
    cat > "$STAGE/daemon" <<'DAEMON'
#!/system/bin/sh
MODDIR=$1
exec /system/bin/app_process -Djava.class.path="$MODDIR/tsoss_classes.dex" "$MODDIR" --nice-name=TrickyStoreOSS io.github.beakthoven.TrickyStoreOSS.MainKt
DAEMON

    # TrickyStoreOSS needs a few extra keystore sepolicy rules beyond ours.
    if [[ -f "$TSOSS_EXTRACT/sepolicy.rule" ]]; then
        while IFS= read -r rule || [[ -n "$rule" ]]; do
            [[ -z "$rule" ]] && continue
            grep -qxF "$rule" "$STAGE/sepolicy.rule" 2>/dev/null || echo "$rule" >> "$STAGE/sepolicy.rule"
        done < "$TSOSS_EXTRACT/sepolicy.rule"
        green "    merged TrickyStoreOSS sepolicy rules"
    fi

    [[ -f "$TSOSS_EXTRACT/keybox.xml" ]] && cp "$TSOSS_EXTRACT/keybox.xml" "$STAGE/keybox.xml"
else
    # TEESimulator (JingMatrix): the original TEESimulator. Ships its Kotlin
    # daemon dex + a native keymint/keystore interceptor per 64-bit ABI. We stage
    # the whole payload under teesim/ (so its classes.dex never collides with
    # PIF's) and attest/teesim.sh app_process-launches it and bridges the config.
    TEESIM_EXTRACT="$BUILD/teesim_extracted"
    rm -rf "$TEESIM_EXTRACT"
    mkdir -p "$TEESIM_EXTRACT"
    unzip -qq -o "$teesim_zip" -d "$TEESIM_EXTRACT"

    [[ -f "$TEESIM_EXTRACT/classes.dex" ]] || die "TEESimulator (JingMatrix) ZIP missing classes.dex — upstream layout changed"
    mkdir -p "$STAGE/teesim"
    cp "$TEESIM_EXTRACT/classes.dex" "$STAGE/teesim/classes.dex"
    [[ -f "$TEESIM_EXTRACT/config.default.json" ]] \
        && cp "$TEESIM_EXTRACT/config.default.json" "$STAGE/teesim/config.default.json"

    # Per-ABI native payload. TEESimulator's keymint lib is ~19 MB PER ABI, so
    # shipping both arm64-v8a and x86_64 would make an 18 MB zip. teesim is 64-bit
    # only and virtually every rooted device is arm64, so the release ships
    # arm64-v8a ONLY (~9 MB). x86_64 (emulators / a few Chromebooks) can self-build
    # with TEESIM_ABIS="arm64-v8a x86_64".
    TEESIM_ABIS="${TEESIM_ABIS:-arm64-v8a}"
    _teesim_abis=0
    for abi in $TEESIM_ABIS; do
        if [[ -d "$TEESIM_EXTRACT/$abi" ]]; then
            mkdir -p "$STAGE/teesim/$abi"
            cp "$TEESIM_EXTRACT/$abi"/* "$STAGE/teesim/$abi/" 2>/dev/null
            _teesim_abis=$((_teesim_abis+1))
        fi
    done
    [[ "$_teesim_abis" -gt 0 ]] || die "TEESimulator (JingMatrix) ZIP has none of: $TEESIM_ABIS — upstream layout changed"
    [[ -f "$STAGE/teesim/arm64-v8a/inject" ]] \
        || die "TEESimulator (JingMatrix) ZIP missing arm64-v8a/inject — upstream layout changed"

    # Merge its keystore sepolicy rules into ours (same as TrickyStoreOSS).
    if [[ -f "$TEESIM_EXTRACT/sepolicy.rule" ]]; then
        while IFS= read -r rule || [[ -n "$rule" ]]; do
            [[ -z "$rule" ]] && continue
            grep -qxF "$rule" "$STAGE/sepolicy.rule" 2>/dev/null || echo "$rule" >> "$STAGE/sepolicy.rule"
        done < "$TEESIM_EXTRACT/sepolicy.rule"
        green "    merged TEESimulator (JingMatrix) sepolicy rules"
    fi
fi

# 2b) Overlay the matching engine adapter as attest.sh. customize.sh sources it
#     for attest_install; service.sh sources it for attest_start / attest_alive.
cp "$ATTEST_SRC/$ENGINE_KIND.sh" "$STAGE/attest.sh"
green "    attestation engine: $ENGINE_KIND"

# 3) Extract this line's Play Integrity engine: zygisk libs, classes.dex (PIF's,
#    stays as classes.dex) and the upstream helper scripts named by $PIF_FILES.
#    Skipped entirely for a PIF-less line — it ships no zygisk and no classes.dex.
if [[ "$PIF_NONE" == "1" ]]; then
    green "    PIF-less line — skipping zygisk / classes.dex staging"
else
PIF_EXTRACT="$BUILD/pif_extracted-$VARIANT"
rm -rf "$PIF_EXTRACT"
mkdir -p "$PIF_EXTRACT"
unzip -qq -o "$pif_zip" -d "$PIF_EXTRACT"

mkdir -p "$STAGE/zygisk"
cp "$PIF_EXTRACT/zygisk"/*.so "$STAGE/zygisk/" 2>/dev/null || die "PIF zygisk libs missing"

[[ -f "$PIF_EXTRACT/classes.dex" ]] || die "PIF ZIP missing classes.dex"
cp "$PIF_EXTRACT/classes.dex" "$STAGE/classes.dex"

for f in $PIF_FILES; do
    if [[ -f "$PIF_EXTRACT/$f" ]]; then
        cp "$PIF_EXTRACT/$f" "$STAGE/$f"
    fi
done
# A missing helper means the fingerprint refresh does nothing at run time, and
# nothing says so until a verdict drops. Fail the build instead.
for f in $PIF_REQUIRED; do
    [[ -f "$STAGE/$f" ]] \
        || die "$VARIANT: PIF zip has no $f — upstream layout changed, update module-variants/$VARIANT/build.conf"
done
fi

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
for f in $PIF_PATCH_PATHS; do
    f="$STAGE/$f"
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
if [[ "$PATCH_AUTOPIF4_WGET" == "1" && -f "$STAGE/autopif4.sh" ]]; then
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
# Some engines' zygisk verifies module.prop against a checksum baked into the
# upstream release and drops its payload when it disagrees — which it always
# does, since we ship our own module.prop. The check's early-out is
# access(<moddir>/update)==0, so the access() path is repointed at zygisk/, a
# directory that always exists beside the .so. Same length (6 bytes), so the
# rewrite stays in place. Enabled per line via PIF_ANTITAMPER in build.conf.
SO_UNTAMPER() {
    if command -v perl >/dev/null 2>&1; then
        perl -0777 -pi -e \
            's{/data/adb/modules/tricky_store/////update}{/data/adb/modules/tricky_store/////zygisk}g' "$1"
    else
        python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
d = open(p, 'rb').read()
d = d.replace(b'/data/adb/modules/tricky_store/////update',
              b'/data/adb/modules/tricky_store/////zygisk')
open(p, 'wb').write(d)
PY
    fi
}

for so in "$STAGE/zygisk"/*.so; do
    [[ -f "$so" ]] || continue
    SO_PATCH "$so"
    [[ "$PIF_ANTITAMPER" == "1" ]] && SO_UNTAMPER "$so"
    new_refs=$(grep -ac "modules/tricky_store" "$so" 2>/dev/null) || new_refs=0
    green "    $(basename "$so"): tricky_store path refs=$new_refs"
done

# The bypass is one hardcoded string away from breaking on any upstream bump,
# and when it breaks the module still installs — it just reports itself tampered
# and stops spoofing, with nothing in the build log to say so. Check it landed.
if [[ "$PIF_ANTITAMPER" == "1" ]]; then
    bold "==> Verifying the module.prop checksum check is bypassed"
    for so in "$STAGE/zygisk"/*.so; do
        [[ -f "$so" ]] || continue
        if grep -aqF '/data/adb/modules/tricky_store/////update' "$so"; then
            die "$(basename "$so"): access() path still points at /update — the bypass did not apply."
        fi
        grep -aqF '/data/adb/modules/tricky_store/////zygisk' "$so" \
            || die "$(basename "$so"): no bypassed access() path found. Upstream changed the check — re-read verifyModule() and update SO_UNTAMPER before shipping, or the module reports itself tampered on device."
        green "    $(basename "$so"): ok"
    done
fi

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
for f in $PIF_PATCH_PATHS; do
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
for f in "$STAGE"/*.sh "$STAGE"/*.prop "$STAGE/daemon" "$STAGE/module.prop" \
         "$STAGE/target.txt" "$STAGE/description.txt" "$STAGE/sepolicy.rule" \
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
  local VERSION OUT_ZIP ATTEST_SUFFIX=""
  [[ "$ENGINE_KIND" == "trickystoreoss" ]] && ATTEST_SUFFIX="-TSOSS"
  [[ "$ENGINE_KIND" == "teesim" ]]         && ATTEST_SUFFIX="-TEESIM"
  VERSION=$(grep '^version=' "$STAGE/module.prop" | cut -d= -f2)
  OUT_ZIP="$OUT/AlwaysStrong-${VERSION}${ZIP_SUFFIX}${ATTEST_SUFFIX}.zip"
  rm -f "$OUT_ZIP"

  bold "==> Packaging $OUT_ZIP"
  ( cd "$STAGE" && zip -qr "$OUT_ZIP" . -x "*.DS_Store" )
  BUILT_ZIPS+=("$OUT_ZIP")
}

# ---------- Run every requested line ----------
for v in "${VARIANTS[@]}"; do
    build_variant "$v"
done

# ---------- Summary ----------
summarize() {
    local zip="$1"
    green "  Built: $(basename "$zip")  ($(du -h "$zip" | cut -f1))"
    green "  Path:  $zip"
    if [[ -n "$SHA" ]]; then
        green "  SHA256: $($SHA "$zip" | awk '{print $1}')"
    fi
}
green ""
for z in "${BUILT_ZIPS[@]}"; do
    summarize "$z"
    green ""
done
