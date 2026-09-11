# shellcheck disable=SC2034
SKIPUNZIP=1
MIN_SDK=29
CONFIG_DIR=/data/adb/tricky_store

if [ "$BOOTMODE" != true ]; then
  abort "install from a root manager, not recovery"
fi
if [ "$KSU" = true ] && [ "$KSU_VER_CODE" -lt 10670 ]; then
  abort "please update KernelSU + manager first"
fi

case "$ARCH" in
  arm64) ABI_DIR="arm64-v8a" ;;
  arm)   ABI_DIR="armeabi-v7a" ;;
  x64)   ABI_DIR="x86_64" ;;
  x86)   ABI_DIR="x86" ;;
  *)     abort "unsupported arch: $ARCH" ;;
esac

[ "$API" -lt "$MIN_SDK" ] && abort "needs Android 10+ (SDK $MIN_SDK)"

VERSION=$(grep_prop version "${TMPDIR}/module.prop")
# read the name from module.prop so the -inject build shows "[inject]" here too
NAME=$(grep_prop name "${TMPDIR}/module.prop")
install_file() { unzip -qqjo "$ZIPFILE" "$1" -d "$2" || abort "extract failed: $1"; }

ui_print "${NAME:-AlwaysStrong} $VERSION"
ui_print "by @evokerr  -  t.me/keyboxstrong"
ui_print ""

# stop anything that might be holding our lib files (upgrade-in-place). The
# list is a superset across both engines — killing an absent process is a no-op.
for proc in TEESimulator supervisor daemon ta-enhanced TrickyStoreOSS; do
  for pid in $(pidof "$proc" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
done
pkill -9 -f TEESimulator 2>/dev/null || true

# --- conflict cleanup ----------------------------------------------------
# Keystore / TEE / target-list / prop modules always conflict with the
# attestation engine. The PIF-family (Build spoof) only conflicts with a line
# that bundles its own PlayIntegrityFork — the PIF-less "Lite" line ships none and
# is meant to run alongside the user's own PIF, so Lite does NOT remove them.
CONFLICT_LIST="tricky_store_v2 TrickyStore \
  tee_simulator TEESimulator TEESimulator-RS \
  safetynet-fix Universal_SafetyNet_Fix \
  MagiskHidePropsConf \
  TA_utl tricky_addon TA_enhanced tsupport-advance \
  Yurikey specter"
case "$NAME" in
  *"[Lite]"*) ui_print "- Lite build — keeping any standalone PlayIntegrityFork" ;;
  *) CONFLICT_LIST="$CONFLICT_LIST playintegrityfix playintegrityfork play_integrity_fix playcurl playcurlNEXT pif_strong pif_force" ;;
esac
CONFLICTS=0
for c in $CONFLICT_LIST ; do
  cp_dir="/data/adb/modules/$c"
  if [ -d "$cp_dir" ] && [ "$(basename "$cp_dir")" != "$(basename "$MODPATH")" ]; then
    CONFLICTS=$((CONFLICTS+1))
    [ -f "$cp_dir/uninstall.sh" ] && sh "$cp_dir/uninstall.sh" 2>/dev/null || true
    touch "$cp_dir/disable" "$cp_dir/remove"
    rm -rf "$cp_dir" 2>/dev/null
  fi
  [ -d "/data/adb/modules_update/$c" ] && rm -rf "/data/adb/modules_update/$c" 2>/dev/null
done
# MeowDump's "Integrity Box" ships under the SAME id as osm0sis PlayIntegrityFork
# (playintegrityfix). The Lite line keeps the plain Fork but must still drop
# Integrity Box (a full keystore/attestation toolkit) — told apart by module.prop.
_ib=/data/adb/modules/playintegrityfix
if [ -d "$_ib" ] && [ "$(basename "$_ib")" != "$(basename "$MODPATH")" ] \
   && grep -qiE 'MeowDump|Integrity-Box|integrity-box|webuiIcon' "$_ib/module.prop" 2>/dev/null; then
  CONFLICTS=$((CONFLICTS+1))
  [ -f "$_ib/uninstall.sh" ] && sh "$_ib/uninstall.sh" 2>/dev/null || true
  touch "$_ib/disable" "$_ib/remove"
  rm -rf "$_ib" /data/adb/modules_update/playintegrityfix 2>/dev/null
  ui_print "- removed Integrity Box (shares the playintegrityfix id)"
fi
if [ $CONFLICTS -eq 0 ]; then
  ui_print "no conflicting modules"
else
  ui_print "removed $CONFLICTS conflicting module(s)"
fi

# --- extract our scripts + configs ---------------------------------------
# engine.sh first: it names the upstream files this build's Play Integrity
# engine needs ($ENGINE_FILES). Everything else here is engine-neutral.
install_file "engine.sh" "$MODPATH"
# shellcheck source=/dev/null
. "$MODPATH/engine.sh"

for f in module.prop service.sh post-fs-data.sh action.sh \
         uninstall.sh common_func.sh sepolicy.rule \
         keybox_fetch.sh build_target_txt.sh status_fetch.sh description.txt \
         rom_spoof_block.sh conflict_scan.sh sync_patch.sh \
         pif_native_fetch.sh prop_unify.sh logcat_cleanup.sh collect_logs.sh \
         import_pif.sh reapply_spoof.sh lite_pif_sync.sh reset_defaults.sh \
         pif_fallback_1.prop pif_fallback_2.prop \
         target.txt daemon \
         $ENGINE_FILES ; do
  install_file "$f" "$MODPATH"
done

# module banner shown by the root manager (module.prop -> banner=.../banner.png)
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "^.*banner\.png"; then
  install_file "banner.png" "$MODPATH"
  chmod 644 "$MODPATH/banner.png" 2>/dev/null
fi

# --- attestation engine (TEESimulator-RS | TrickyStoreOSS) ----------------
# The per-engine install steps live in attest.sh, which build.sh generates from
# attest/<engine>.sh. It runs with $ABI_DIR / $ARCH / $ZIPFILE / $MODPATH and
# install_file() + ui_print() in scope, and installs that engine's binaries.
install_file "attest.sh" "$MODPATH"
# shellcheck source=/dev/null
. "$MODPATH/attest.sh"
attest_install

# --- PIF zygisk + dex ----------------------------------------------------
# Ship whatever ABIs upstream built. PlayIntegrityFork covers all four;
# PlayIntegrityFix inject-s is ARM-only, so on x86 that build has no zygisk to
# install — the TEE half still runs, the Play Integrity spoof can't, and the
# install says so rather than half-working in silence.
#
# A PIF-less "Lite" line (engine.sh sets ENGINE=none) ships no zygisk and no
# classes.dex at all — only the TEE/TSOSS attestation + keybox fetcher. Skip the
# whole Play Integrity install for it.
if [ "$ENGINE" = "none" ]; then
  ui_print "PIF-less build — hardware attestation + keybox only"
  ui_print "no Play Integrity fingerprint spoof in this build"
else
mkdir -p "$MODPATH/zygisk"
ZN=0
for z in arm64-v8a armeabi-v7a x86 x86_64; do
  if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "zygisk/$z.so"; then
    unzip -qqjo "$ZIPFILE" "zygisk/$z.so" -d "$MODPATH/zygisk" 2>/dev/null
    ZN=$((ZN+1))
  fi
done
install_file "classes.dex" "$MODPATH"

HAS_ZYGISK_SO=0
[ -f "$MODPATH/zygisk/$ABI_DIR.so" ] && HAS_ZYGISK_SO=1

if [ $HAS_ZYGISK_SO -eq 0 ]; then
  ui_print "⚠️ no PIF zygisk for $ABI_DIR ($ENGINE_NAME is ARM-only)"
  ui_print "⚠️ TEE works, Play Integrity spoof won't"
  ui_print "⚠️ use the default build for $ABI_DIR"
# --- Zygisk provider check — PIF's zygisk needs a Zygisk host --------------
# The common silent-failure setup is Zygisk-less KernelSU: KSU has NO built-in
# Zygisk, so without ZygiskNext / ReZygisk the PIF spoof never loads and STRONG
# quietly fails. Magisk / APatch ship (or host) Zygisk themselves. Warn only on
# the real footgun to avoid false alarms.
elif [ "$KSU" = "true" ] \
     && [ ! -d /data/adb/modules/zygisksu ] && [ ! -d /data/adb/modules/rezygisk ] \
     && [ ! -d /data/adb/modules/neozygisk ]; then
  ui_print "⚠️ KernelSU without Zygisk Next / ReZygisk / NeoZygisk"
  ui_print "⚠️ install one or PIF spoof won't load (no STRONG)"
else
  ui_print "zygisk found"
fi
fi

# --- aswatcher native binary (inotify target.txt + Xposed exclude + conflict)
mkdir -p "$MODPATH/bin/$ABI_DIR"
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "bin/$ABI_DIR/aswatcher"; then
  install_file "bin/$ABI_DIR/aswatcher" "$MODPATH/bin/$ABI_DIR"
  chmod 755 "$MODPATH/bin/$ABI_DIR/aswatcher"
else
  ui_print "warning: no aswatcher binary for $ABI_DIR"
fi

# --- asfetch native HTTPS fetcher (arm devices only; TLS fallback for CDNs)
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "bin/$ABI_DIR/asfetch"; then
  install_file "bin/$ABI_DIR/asfetch" "$MODPATH/bin/$ABI_DIR"
  chmod 755 "$MODPATH/bin/$ABI_DIR/asfetch"
fi

chmod 755 "$MODPATH/daemon" "$MODPATH/supervisor" "$MODPATH/inject" \
          "$MODPATH"/*.sh 2>/dev/null

# --- WebUI (KSU / APatch / MMRL) — single self-contained index.html
mkdir -p "$MODPATH/webroot"
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "webroot/index.html"; then
  install_file "webroot/index.html" "$MODPATH/webroot"
  chmod 644 "$MODPATH/webroot/index.html"
  # Magisk has no built-in WebUI host. The standalone WebUI app is fetched
  # from GitHub and installed on the first [Action] press (see action.sh).
  if [ "$KSU" != true ] && [ "$APATCH" != true ]; then
    ui_print "WebUI: app downloads + installs on first Action tap"
  fi
else
  ui_print "warning: WebUI index.html missing from package"
fi

# --- /data/adb/tricky_store config ----------------------------------------
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_DIR/keybox.xml" ]; then
  ui_print "keybox kept ($(wc -c < "$CONFIG_DIR/keybox.xml") bytes)"
else
  # No keybox yet: seed the upstream demo keybox so the engine has a file to
  # load. It is public, so it never reaches STRONG on its own — Action fetches
  # the real one from the mirror (and says so when it cannot).
  install_file "keybox.xml" "$CONFIG_DIR"
  ui_print "demo keybox seeded — the real one is fetched on first boot"
fi

# target.txt is (re)built on boot (service.sh) and on every [Action] tap — just
# drop a default seed here so TrickyStore has something to read on first boot.
[ -f "$CONFIG_DIR/target.txt" ] || install_file "target.txt" "$CONFIG_DIR"

if [ ! -f "$CONFIG_DIR/hbk" ]; then
  head -c 32 /dev/random > "$CONFIG_DIR/hbk"
  chmod 600 "$CONFIG_DIR/hbk"
fi
rm -f "$CONFIG_DIR/tee_status.txt" "$CONFIG_DIR/tee_status" 2>/dev/null

ui_print ""
ui_print "installed. reboot, then tap [Action] to refresh."
ui_print ""
