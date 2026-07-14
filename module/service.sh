#!/system/bin/sh
MODDIR="${0%/*}"
MODPATH="$MODDIR"
cd "$MODDIR"

set +o standalone 2>/dev/null
unset ASH_STANDALONE

[ -f "$MODDIR/common_func.sh" ] && . "$MODDIR/common_func.sh"

# --- Recovery mode guard ---
resetprop_if_match ro.boot.mode recovery unknown
resetprop_if_match ro.bootmode recovery unknown
resetprop_if_match ro.boot.bootmode recovery unknown
resetprop_if_match vendor.boot.mode recovery unknown
resetprop_if_match vendor.boot.bootmode recovery unknown

# --- SELinux enforcement ---
resetprop_if_diff ro.boot.selinux enforcing
if ! ${SKIPDELPROP:-false}; then
    delprop_if_exist ro.build.selinux 2>/dev/null || true
fi
if [ "$(toybox cat /sys/fs/selinux/enforce 2>/dev/null)" = "0" ]; then
    chmod 640 /sys/fs/selinux/enforce
    chmod 440 /sys/fs/selinux/policy
fi

# --- Late properties (after boot_completed) — required for some OEMs ---
{
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done

# Verified-boot / bootloader-lock fingerprint
resetprop_if_diff ro.secureboot.lockstate locked
resetprop_if_diff ro.boot.flash.locked 1
resetprop_if_diff ro.boot.realme.lockstate 1
resetprop_if_diff ro.boot.vbmeta.device_state locked
resetprop_if_diff vendor.boot.verifiedbootstate green
resetprop_if_diff ro.boot.verifiedbootstate green
resetprop_if_diff ro.boot.veritymode enforcing
resetprop_if_diff vendor.boot.veritymode enforcing
resetprop_if_diff vendor.boot.vbmeta.device_state locked
resetprop_if_diff sys.oem_unlock_allowed 0
resetprop_if_diff ro.boot.warranty_bit 0
resetprop_if_diff ro.warranty_bit 0
resetprop_if_diff ro.secure 1
resetprop_if_diff ro.debuggable 0
resetprop_if_diff ro.adb.secure 1
resetprop_if_diff service.adb.root 0
resetprop_if_diff ro.boot.vbmeta.invalidate_on_error yes

# --- LineageOS prop scrub (hide derivative-ROM markers from PI checks) ---
LV=$(getprop ro.product.vendor.name 2>/dev/null)
case "$LV" in
    lineage_*) resetprop -n ro.product.vendor.name "${LV#lineage_}" ;;
esac
for LP in vendor.camera.aux.packagelist persist.vendor.camera.privapp.list; do
    LCV=$(getprop "$LP" 2>/dev/null)
    case "$LCV" in
        *org.lineageos.aperture*)
            LCV=$(echo "$LCV" | sed -e 's/,org\.lineageos\.aperture//g' \
                                    -e 's/org\.lineageos\.aperture,//g' \
                                    -e 's/^org\.lineageos\.aperture$//')
            resetprop -n "$LP" "$LCV"
            ;;
    esac
done
if [ -n "$(getprop init.svc.vendor.lineage_health 2>/dev/null)" ]; then
    stop vendor.lineage_health 2>/dev/null
    resetprop --delete init.svc.vendor.lineage_health 2>/dev/null
fi
}&

# --- Conflict re-scan on every boot ---
# A user can install a conflicting module AFTER they've installed AlwaysStrong
# (the install-time scan in customize.sh only fires once). Re-run the same
# disable-known-conflicts pass at every boot so a fresh install of e.g.
# playintegrityfix doesn't silently break our hooks.
if [ -x "$MODDIR/conflict_scan.sh" ]; then
    MODPATH="$MODDIR" sh "$MODDIR/conflict_scan.sh" >/dev/null 2>&1
    n=$?
    [ "$n" -gt 0 ] && log -t "AlwaysStrong" "disabled $n conflicting module(s) at boot"
fi

# --- Wait for boot, then start TEE simulator ---
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done

# Kill any stale TEE / aswatcher processes from a previous boot
for proc in TEESimulator supervisor daemon aswatcher; do
  for pid in $(pidof "$proc" 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null
  done
done
pkill -9 -f TEESimulator 2>/dev/null || true

# Fork-based supervisor + daemon (TEESimulator-RS standard pattern)
"$MODDIR/supervisor" "$MODDIR/daemon" "$MODDIR" &

# --- aswatcher native daemon (inotify target.txt + Xposed + conflict) ---
case "$(uname -m)" in
    aarch64)       AS_ABI=arm64-v8a ;;
    armv7*|armv8l) AS_ABI=armeabi-v7a ;;
    x86_64)        AS_ABI=x86_64 ;;
    i?86)          AS_ABI=x86 ;;
    *)             AS_ABI="" ;;
esac
AS_BIN="$MODDIR/bin/$AS_ABI/aswatcher"
if [ -x "$AS_BIN" ]; then
    {
        sleep 5
        "$AS_BIN" &
        log -t "AlwaysStrong" "aswatcher launched ($AS_ABI)"
    } &
fi

# --- VBMeta digest (deferred, bounded) ---
# Reading the whole vbmeta partition during early boot can hang the boot
# animation on some Xiaomi devices. Skip if already set, only read 64KiB.
{
sleep 60
CURRENT_DIGEST=$(resetprop ro.boot.vbmeta.digest)
if [ -z "$CURRENT_DIGEST" ] || echo "$CURRENT_DIGEST" | grep -qE '^0+$'; then
    for p in /dev/block/by-name/vbmeta /dev/block/by-name/vbmeta_a /dev/block/bootdevice/by-name/vbmeta; do
        [ -e "$p" ] && VBMETA_BLK="$p" && break
    done
    if [ -n "$VBMETA_BLK" ]; then
        DIGEST=$(dd if="$VBMETA_BLK" bs=4096 count=16 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
        if [ -n "$DIGEST" ]; then
            resetprop -n ro.boot.vbmeta.digest "$DIGEST"
            log -t "AlwaysStrong" "VBMeta digest set: ${DIGEST:0:16}..."
        fi
    fi
fi
}&

# --- Housekeeping in background ---
{
    sleep 3
    # Hide TWRP-style recovery folders on /sdcard if empty
    for rdir in TWRP Fox OrangeFox PBRP PitchBlack Recovery; do
        target="/sdcard/$rdir"
        if [ -d "$target" ] && [ "$(ls -A "$target" 2>/dev/null)" ]; then
            mv "$target" "/data/adb/.recovery_backup_${rdir}" 2>/dev/null
        elif [ -d "$target" ]; then
            rmdir "$target" 2>/dev/null
        fi
    done
    rm -f /sdcard/.twrps 2>/dev/null
}&

# --- TEESimulator + aswatcher watchdog ---
{
    while true; do
        sleep 120
        if ! pidof TEESimulator >/dev/null 2>&1 && ! pidof daemon >/dev/null 2>&1; then
            log -t "AlwaysStrong" "TEE daemon died, restarting..."
            "$MODDIR/supervisor" "$MODDIR/daemon" "$MODDIR" &
        fi
        if [ -x "$AS_BIN" ] && ! pidof aswatcher >/dev/null 2>&1; then
            log -t "AlwaysStrong" "aswatcher died, restarting..."
            "$AS_BIN" &
        fi
    done
}&

# --- First-boot bootstrap (one-shot per module install) ------------------
# Marker file lives inside MODDIR — gets wiped when the module is
# uninstalled, so a reinstall re-bootstraps cleanly. On subsequent boots
# this whole block is a no-op; users press [Action] to refresh manually.
if [ ! -f "$MODDIR/.bootstrapped" ]; then
{
    sleep 20
    # network usually up well before this, but defer further for slow boots
    j=0
    until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do
        j=$((j+1)); [ $j -gt 30 ] && break
        sleep 2
    done
    log -t "AlwaysStrong-boot" "first boot: starting bootstrap"

    # 1. keybox (skipped entirely in custom-keybox mode — user's own keybox)
    if [ ! -f /data/adb/tricky_store/custom_keybox ] && [ -x "$MODDIR/keybox_fetch.sh" ]; then
        sh "$MODDIR/keybox_fetch.sh" 2>&1 | log -t "AlwaysStrong-boot"
    fi

    # 2. fingerprint + security patch. native crawl (primary) fetches AND runs
    #    migrate.sh -> custom.pif.prop (the file PIF reads), fast; autopif4 (whose
    #    crawl hangs on some devices) is the fallback. Both produce custom.pif.prop.
    FP_DONE=0
    if [ -x "$MODDIR/pif_native_fetch.sh" ]; then
        sh "$MODDIR/pif_native_fetch.sh" >/data/adb/tricky_store/autopif.log 2>&1 && FP_DONE=1
        cat /data/adb/tricky_store/autopif.log 2>/dev/null | log -t "AlwaysStrong-boot"
    fi
    if [ "$FP_DONE" = 0 ] && [ -f "$MODDIR/autopif4.sh" ]; then
        sh "$MODDIR/autopif4.sh" -s -m 2>&1 | log -t "AlwaysStrong-boot"
    fi

    # 2b. sync the attestation/system security patch to the fresh fingerprint
    [ -f "$MODDIR/sync_patch.sh" ] && sh "$MODDIR/sync_patch.sh" 2>&1 | log -t "AlwaysStrong-boot"

    # 3. enforce STRONG-friendly settings on every produced pif.prop variant
    for CPIF in "$MODDIR/custom.pif.prop" "$MODDIR/pif.prop" \
                /data/adb/tricky_store/custom.pif.prop /data/adb/tricky_store/pif.prop; do
        [ -f "$CPIF" ] || continue
        for kv in "spoofProvider=0" "spoofVendingFinger=1" "spoofBuild=1" \
                  "spoofProps=1" "spoofSignature=0" "spoofVendingSdk=0"; do
            k="${kv%=*}"; v="${kv#*=}"
            if grep -qE "^${k}=" "$CPIF"; then
                sed -i "s|^${k}=.*|${k}=${v}|" "$CPIF"
            else
                echo "${k}=${v}" >> "$CPIF"
            fi
        done
        log -t "AlwaysStrong-boot" "STRONG enforced on $CPIF"
    done

    # 4. restart PI consumers so they pick up the new state
    killall -9 com.google.android.gms.unstable 2>/dev/null
    killall -9 com.android.vending 2>/dev/null

    # NOTE: deliberately do NOT call status_fetch here. We don't want
    # the 🟢 status prefix to appear in module.prop's description before
    # the user has interacted with the module at all — the description
    # stays as the clean text from module.prop until the user presses
    # [Action] (or the hourly refresh fires, whichever happens first).

    # mark done regardless of individual step outcome — user can press
    # [Action] to retry if any step failed (e.g. no internet on first boot)
    touch "$MODDIR/.bootstrapped"
    log -t "AlwaysStrong-boot" "bootstrap done"
}&
fi

# --- Hourly refresh (fingerprint + keybox, each toggle-able from WebUI) --
# WebUI writes flag files into /data/adb/tricky_store/ to opt OUT:
#   no_auto_fp      -> skip the autopif4 refresh
#   no_auto_keybox  -> skip the keybox fetch
# Keybox-only restarts PI when it actually changed (exit 0); fingerprint
# updates are picked up naturally on the next PI invocation, so we don't
# kick running banking apps for cosmetic refreshes.
{
    CFG=/data/adb/tricky_store
    export MODPATH="$MODDIR"
    while true; do
        # Interval is user-configurable from the WebUI. Default 1h, floor 60s
        # so a misconfigured 0/-1/garbage doesn't busy-spin the loop.
        INT=$(cat "$CFG/hourly_interval_sec" 2>/dev/null)
        case "$INT" in
            ''|*[!0-9]*) INT=3600 ;;
        esac
        [ "$INT" -lt 60 ] && INT=60
        sleep "$INT"
        if [ ! -f "$CFG/no_auto_fp" ]; then
            FP_DONE=0
            if [ -x "$MODDIR/pif_native_fetch.sh" ]; then
                sh "$MODDIR/pif_native_fetch.sh" >"$CFG/autopif.log" 2>&1 && FP_DONE=1
                cat "$CFG/autopif.log" 2>/dev/null | log -t "AlwaysStrong-hourly"
            fi
            if [ "$FP_DONE" = 0 ] && [ -f "$MODDIR/autopif4.sh" ]; then
                sh "$MODDIR/autopif4.sh" -s -m 2>&1 | log -t "AlwaysStrong-hourly"
            fi
            [ -f "$MODDIR/sync_patch.sh" ] && sh "$MODDIR/sync_patch.sh" 2>&1 | log -t "AlwaysStrong-hourly"
        fi
        if [ ! -f "$CFG/custom_keybox" ] && [ ! -f "$CFG/no_auto_keybox" ] && [ -x "$MODDIR/keybox_fetch.sh" ]; then
            kbout=$(sh "$MODDIR/keybox_fetch.sh" 2>&1)
            kbrc=$?
            [ -n "$kbout" ] && echo "$kbout" | log -t "AlwaysStrong-hourly"
            if [ "$kbrc" = "0" ]; then
                log -t "AlwaysStrong-hourly" "keybox updated, restarting PI"
                killall -9 com.google.android.gms.unstable 2>/dev/null
                killall -9 com.android.vending 2>/dev/null
            fi
        fi
        # Status — independent of toggles; cheap GET, idempotent module.prop write
        if [ -x "$MODDIR/status_fetch.sh" ]; then
            sh "$MODDIR/status_fetch.sh" 2>&1 | log -t "AlwaysStrong-hourly"
        fi
    done
}&
