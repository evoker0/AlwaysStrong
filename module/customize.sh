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
install_file() { unzip -qqjo "$ZIPFILE" "$1" -d "$2" || abort "extract failed: $1"; }

ui_print "AlwaysStrong $VERSION"
ui_print "by @evokerr  -  t.me/keyboxstrong"
ui_print ""

# stop anything that might be holding our lib files (upgrade-in-place)
for proc in TEESimulator supervisor daemon ta-enhanced; do
  for pid in $(pidof "$proc" 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
done
pkill -9 -f TEESimulator 2>/dev/null || true

# --- conflict cleanup (19 known modules) ---------------------------------
CONFLICTS=0
for c in \
  playintegrityfix playintegrityfork play_integrity_fix \
  playcurl playcurlNEXT \
  tricky_store_v2 TrickyStore \
  tee_simulator TEESimulator TEESimulator-RS \
  safetynet-fix Universal_SafetyNet_Fix \
  MagiskHidePropsConf \
  TA_utl tricky_addon TA_enhanced tsupport-advance \
  Yurikey \
  pif_strong pif_force ; do
  cp_dir="/data/adb/modules/$c"
  if [ -d "$cp_dir" ] && [ "$(basename "$cp_dir")" != "$(basename "$MODPATH")" ]; then
    CONFLICTS=$((CONFLICTS+1))
    [ -f "$cp_dir/uninstall.sh" ] && sh "$cp_dir/uninstall.sh" 2>/dev/null || true
    touch "$cp_dir/disable" "$cp_dir/remove"
    rm -rf "$cp_dir" 2>/dev/null
  fi
  [ -d "/data/adb/modules_update/$c" ] && rm -rf "/data/adb/modules_update/$c" 2>/dev/null
done
if [ $CONFLICTS -eq 0 ]; then
  ui_print "no conflicting modules"
else
  ui_print "removed $CONFLICTS conflicting module(s)"
fi

# --- extract our scripts + configs ---------------------------------------
for f in module.prop service.sh post-fs-data.sh action.sh \
         uninstall.sh common_func.sh common_setup.sh sepolicy.rule \
         keybox_fetch.sh build_target_txt.sh status_fetch.sh description.txt \
         rom_spoof_block.sh conflict_scan.sh sync_patch.sh \
         autopif4.sh killpi.sh migrate.sh \
         app_replace_list.txt example.pif.prop target.txt daemon ; do
  install_file "$f" "$MODPATH"
done

# module banner shown by the root manager (module.prop -> banner=.../banner.png)
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "^.*banner\.png"; then
  install_file "banner.png" "$MODPATH"
  chmod 644 "$MODPATH/banner.png" 2>/dev/null
fi

# --- TEESim binaries ------------------------------------------------------
install_file "lib/$ABI_DIR/libTEESimulator.so" "$MODPATH"
install_file "lib/$ABI_DIR/libinject.so"       "$MODPATH"
install_file "lib/$ABI_DIR/libsupervisor.so"   "$MODPATH"
HAS_CERTGEN=0
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "lib/$ABI_DIR/libcertgen.so"; then
  install_file "lib/$ABI_DIR/libcertgen.so" "$MODPATH"
  HAS_CERTGEN=1
fi
mv "$MODPATH/libinject.so"     "$MODPATH/inject"
mv "$MODPATH/libsupervisor.so" "$MODPATH/supervisor"
install_file "tee_classes.dex" "$MODPATH"
if [ $HAS_CERTGEN -eq 1 ]; then
  ui_print "TEESim installed ($ABI_DIR, native certgen)"
else
  ui_print "TEESim installed ($ABI_DIR)"
fi

# --- PIF zygisk + dex ----------------------------------------------------
mkdir -p "$MODPATH/zygisk"
ZN=0
for z in arm64-v8a armeabi-v7a x86 x86_64; do
  if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "zygisk/$z.so"; then
    unzip -qqjo "$ZIPFILE" "zygisk/$z.so" -d "$MODPATH/zygisk" 2>/dev/null
    ZN=$((ZN+1))
  fi
done
install_file "classes.dex" "$MODPATH"
ui_print "PIF zygisk installed ($ZN ABIs)"

# --- aswatcher native binary (inotify target.txt + Xposed exclude + conflict)
mkdir -p "$MODPATH/bin/$ABI_DIR"
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "bin/$ABI_DIR/aswatcher"; then
  install_file "bin/$ABI_DIR/aswatcher" "$MODPATH/bin/$ABI_DIR"
  chmod 755 "$MODPATH/bin/$ABI_DIR/aswatcher"
else
  ui_print "warning: no aswatcher binary for $ABI_DIR"
fi

chmod 755 "$MODPATH/daemon" "$MODPATH/supervisor" "$MODPATH/inject" \
          "$MODPATH"/*.sh 2>/dev/null

# --- WebUI (KSU / APatch / MMRL) — single self-contained index.html
mkdir -p "$MODPATH/webroot"
if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "webroot/index.html"; then
  install_file "webroot/index.html" "$MODPATH/webroot"
  chmod 644 "$MODPATH/webroot/index.html"
  if [ "$KSU" = true ] || [ "$APATCH" = true ]; then
    ui_print "WebUI ready (open it from your manager)"
  else
    # Magisk has no built-in WebUI host. The standalone WebUI app is fetched
    # from GitHub and installed on the first [Action] press (see action.sh).
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
  install_file "keybox.xml" "$CONFIG_DIR"
  ui_print "default keybox installed (replace for STRONG)"
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
