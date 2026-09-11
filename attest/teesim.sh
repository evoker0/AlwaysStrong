#!/system/bin/sh
# Attestation-engine adapter — TEESimulator (JingMatrix, --engine teesim).
#
# The ORIGINAL TEESimulator: a Kotlin control daemon (launched via app_process)
# plus a native KeyMint/keystore interceptor injected into keystore2. Unlike
# TEESimulator-RS and TrickyStoreOSS it does NOT read /data/adb/tricky_store/ —
# it has its own /data/adb/teesim/config.json. This adapter bridges the two: it
# seeds that config, points TEESimulator's keybox at the AlwaysStrong-managed one
# (so the auto keybox fetch feeds it), and regenerates the config's target-app
# list from /data/adb/tricky_store/target.txt.
#
# 64-bit only (the interceptor is a 64-bit lib injected into the 64-bit keystore2).
# build.sh stages the whole payload under $MODPATH/teesim/:
#   teesim/classes.dex, teesim/config.default.json, teesim/<abi>/{inject,libteesim_*.so,teesim-uds}
#
# build.sh copies this file in as attest.sh. customize.sh sources it for
# attest_install (with $ABI_DIR / $ARCH / $ZIPFILE / $MODPATH + install_file() /
# ui_print() in scope); service.sh sources it for attest_early / attest_start /
# attest_alive / teesim_gen_config (with $MODDIR in scope); keybox_fetch.sh and
# build_target_txt.sh source it for attest_notify (with $MODPATH in scope).

ATTEST=teesim
ATTEST_NAME="TEESimulator (JingMatrix)"
TEESIM_DATA=/data/adb/teesim

# keystore2 injection happens at the service stage, before sys.boot_completed —
# a late start misses the injection window. service.sh honours attest_early.
attest_early() { return 0; }

# Regenerate /data/adb/teesim/config.json from the AlwaysStrong target list.
# The JSON shape mirrors the upstream config.default.json exactly (a known-valid
# schema) with only the "apps" array swapped for the current target.txt, so the
# per-app targeting picked in the WebUI reaches TEESimulator too. Called at boot
# (attest_start), hourly (service.sh) and through attest_notify whenever
# keybox.xml or target.txt is rewritten.
#
# Rewriting config.json is also how the daemon learns about a NEW KEYBOX: its
# FileObserver only watches /data/adb/teesim for config.json / *.xml events, and
# our keybox.xml there is a symlink into /data/adb/tricky_store — inotify never
# reports a write to a symlink's target. The daemon re-reads the keybox bytes on
# every config push, so a fresh config.json is enough to make it pick the new
# keybox up (and to recover from the first-boot "keybox not found" state, where
# it keeps running on no config until one loads).
teesim_gen_config() {
    _tgt=/data/adb/tricky_store/target.txt
    _cfg="$TEESIM_DATA/config.json"
    mkdir -p "$TEESIM_DATA" 2>/dev/null
    _md="${MODDIR:-$MODPATH}"

    # --- device identity: mirror the PIF-spoofed fingerprint --------------
    # CRITICAL for a fork/inject line: PIF spoofs android.os.Build to a Pixel,
    # so TEESimulator's attestation must report the SAME Pixel. Left blank, its
    # KeyMint fields harvest the REAL device, and Play Integrity fails because the
    # attested device (real) mismatches the Build device (Pixel). We copy the
    # brand/model/device/product/manufacturer and the security patch out of the
    # active pif. (No pif — a nopif/Lite line — leaves them blank, which is
    # correct: nothing spoofs Build there, so attesting the real device matches.)
    _pif=""
    for _f in "$_md/custom.pif.prop" /data/adb/tricky_store/custom.pif.prop "$_md/pif.prop" /data/adb/tricky_store/pif.prop; do
        [ -s "$_f" ] && grep -q '^FINGERPRINT=' "$_f" && { _pif="$_f"; break; }
    done
    _pget() { [ -n "$_pif" ] && sed -n "s/^$1=//p" "$_pif" | head -1 | tr -d '\r"'; }
    _fp=$(_pget FINGERPRINT)
    _brand=$(_pget BRAND);   [ -z "$_brand" ] && [ -n "$_fp" ] && _brand=$(printf '%s' "$_fp" | cut -d/ -f1)
    _manu=$(_pget MANUFACTURER)
    _model=$(_pget MODEL)
    _device=$(_pget DEVICE)
    _product=$(_pget PRODUCT)
    _patch=$(_pget SECURITY_PATCH)
    case "$_patch" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) _sys="$_patch" ;;
        *) _sys="today" ;;
    esac

    # --- target apps from target.txt --------------------------------------
    # target.txt is TrickyStore's format, NOT TEESimulator's. It carries syntax
    # teesim rejects: a trailing "!" (force-generate) or "?" (leaf-hack) on a
    # package, and "[keybox.xml]" marker lines that select a per-app keybox and are
    # not package ids at all. TEESimulator's schema only accepts package,
    # package@user, or uid:N (APP_ENTRY_RE) — an unparseable entry silently drops
    # its target, which is exactly why GMS attestation used to fall through to the
    # real HAL. Sanitise every line and emit only valid entries.
    _apps=""
    _add_app() {   # de-dup, then append one already-validated entry
        case "$_apps" in *"\"$1\","*) return ;; esac
        _apps="$_apps      \"$1\",
"
    }
    if [ -f "$_tgt" ]; then
        while IFS= read -r _line || [ -n "$_line" ]; do
            _line=$(printf '%s' "$_line" | tr -d ' \t\r')
            case "$_line" in ''|'#'*|'['*) continue ;; esac   # blanks, comments, [keybox] markers
            _line=${_line%!}; _line=${_line%\?}               # strip TrickyStore force/leaf suffix
            case "$_line" in *.*) : ;; *) continue ;; esac    # must look like a package id
            # keep only package | package@user (schema APP_ENTRY_RE)
            _valid=$(printf '%s' "$_line" | grep -oE '^[A-Za-z0-9_.]+(@[0-9]+)?$')
            [ -n "$_valid" ] && _add_app "$_valid"
        done < "$_tgt"
    fi
    # Always cover the Play Integrity core AND pin their real uids. Package-name
    # targeting alone can miss GMS/DroidGuard (multi-user, shared uid, resolution
    # timing at boot); a raw uid:N token bypasses name resolution and is what makes
    # the interceptor actually claim GMS's generateKey instead of forwarding it to
    # the real HAL. packages.list is root-readable and needs no system_server, so
    # it resolves even at the early boot stage.
    for _p in com.google.android.gms com.android.vending com.google.android.gsf; do
        _add_app "$_p"
        _u=$(sed -n "s/^$_p \([0-9][0-9]*\) .*/\1/p" /data/system/packages.list 2>/dev/null | head -1)
        case "$_u" in [0-9]*) _add_app "uid:$_u" ;; esac
    done
    _apps=$(printf '%s' "$_apps" | sed '$ s/,$//')   # drop the trailing comma

    # mode=generation: mint the whole key in software under the keybox. "patch"
    # keeps the real hardware key and only re-signs its attestation — fewer
    # detection points, but it needs a working hardware KeyMint level. Many custom
    # ROMs (and this repo's target audience) run devices whose real TEE keystore is
    # unreachable (keystore2 reports HARDWARE_TYPE_UNAVAILABLE); there, patch has no
    # base key to re-sign and falls through to the real HAL → BASIC. generation
    # always works and still yields a hardware-backed chain (the keybox is the root).
    cat > "$_cfg" <<EOF
{
  "version": 1,
  "profiles": {
    "default": {
      "keybox": "keybox.xml",
      "mode": "generation",
      "patchLevel": { "system": "$_sys", "vendor": "YYYY-MM-05", "boot": "YYYY-MM-05" },
      "osVersion": "harvested",
      "brand": "$_brand",
      "device": "$_device",
      "product": "$_product",
      "manufacturer": "$_manu",
      "model": "$_model",
      "serial": "",
      "imei": "",
      "meid": "",
      "imei2": "",
      "apps": [
$_apps
      ]
    }
  }
}
EOF
    chmod 0600 "$_cfg" 2>/dev/null
}

attest_install() {
    # 64-bit only — the interceptor is injected into the 64-bit keystore2.
    case "$ARCH" in
        arm64|x64) : ;;
        *) ui_print "⚠️ TEESimulator (JingMatrix) is 64-bit only — $ARCH can't run it"
           ui_print "⚠️ use a -tee or -TSOSS build on this device"
           return 0 ;;
    esac
    # Stage the whole teesim/ payload from the flashed zip.
    unzip -qqo "$ZIPFILE" 'teesim/*' -d "$MODPATH" 2>/dev/null
    # Keep only this device's ABI; other ABIs' ~28 MB of libs are dead weight.
    for _abi in arm64-v8a x86_64; do
        [ "$_abi" = "$ABI_DIR" ] || rm -rf "$MODPATH/teesim/$_abi" 2>/dev/null
    done
    chmod -R 0755 "$MODPATH/teesim" 2>/dev/null

    # The release zip ships arm64-v8a only. On x86_64 there is no payload to run.
    if [ ! -f "$MODPATH/teesim/$ABI_DIR/inject" ]; then
        ui_print "⚠️ no TEESimulator (JingMatrix) payload for $ABI_DIR"
        ui_print "⚠️ this build is arm64-v8a only — use a -tee or -TSOSS build here"
        return 0
    fi

    # Seed the config dir. Point TEESimulator's keybox at the AlwaysStrong-managed
    # one so the automatic keybox fetch feeds this engine; write the initial config
    # from the current target list.
    mkdir -p "$TEESIM_DATA"
    ln -sf /data/adb/tricky_store/keybox.xml "$TEESIM_DATA/keybox.xml" 2>/dev/null
    teesim_gen_config
    ui_print "TEESimulator (JingMatrix) installed ($ABI_DIR)"
}

# app_process control daemon, respawned if it exits. Idempotent via a loop-pid
# marker so the early start and the watchdog don't stack parallel daemons (they
# would fight over the keystore2 injection). The App's argv[0] is the home dir
# where its inject binary + native libs live ($MODDIR/teesim).
attest_start() {
    _lk=/data/adb/tricky_store/.teesim_loop
    if [ -f "$_lk" ] && kill -0 "$(cat "$_lk" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi
    teesim_gen_config
    _home="$MODDIR/teesim"
    [ -f "$_home/classes.dex" ] || return 1
    ( while true; do
        /system/bin/app_process -Djava.class.path="$_home/classes.dex" "$_home" \
            --nice-name=teesim org.matrix.teesim.App "$_home" || break
        sleep 2
      done ) &
    echo $! > "$_lk" 2>/dev/null
}

# The App renames its own process to "TEESimulator" (overriding app_process's
# --nice-name=teesim), so match on the class-path argv instead of a fixed name.
attest_alive() { pgrep -f 'org.matrix.teesim.App' >/dev/null 2>&1 || pidof teesim >/dev/null 2>&1; }

# keybox.xml / target.txt changed: push a fresh config so the daemon re-reads
# both (see teesim_gen_config for why the keybox needs this).
attest_notify() { teesim_gen_config; }
