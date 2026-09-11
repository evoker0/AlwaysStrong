#!/system/bin/sh
MODDIR="${0%/*}"
MODPATH="$MODDIR"
cd "$MODDIR"

# Probe in a subshell first: under mksh / toybox sh the option is unknown and a
# bare `set +o standalone` is a fatal special-builtin error (see action.sh).
(set +o standalone) 2>/dev/null && set +o standalone
unset ASH_STANDALONE

[ -f "$MODDIR/common_func.sh" ] && . "$MODDIR/common_func.sh"

# --- Play Integrity engine adapter ---
# Which prop file the zygisk reads, and what its spoof flags are called, is all
# that differs between the two builds. engine.sh owns it; everything below is
# identical in both.
CONFIG_DIR=/data/adb/tricky_store
if [ -f "$MODDIR/engine.sh" ]; then
    . "$MODDIR/engine.sh"
else
    log -t "AlwaysStrong" "engine.sh missing — no fingerprint handling this boot"
    engine_autopif()       { return 1; }
    engine_install_pif()   { return 1; }
    engine_enforce_spoof() { return 0; }
    ENGINE=none
fi

# --- Attestation engine adapter (TEESimulator-RS | TrickyStoreOSS) -----------
# build.sh overlays exactly one attest.sh; the daemon start/liveness below go
# through it. Fall back to the TEESimulator pattern if it is somehow missing.
if [ -f "$MODDIR/attest.sh" ]; then
    . "$MODDIR/attest.sh"
else
    attest_early() { return 1; }
    attest_start() { "$MODDIR/supervisor" "$MODDIR/daemon" "$MODDIR" & }
    attest_alive() { pidof TEESimulator >/dev/null 2>&1 || pidof daemon >/dev/null 2>&1; }
fi

# Engines that hijack keystore2 (TrickyStoreOSS) must start at the service stage,
# before sys.boot_completed — a late start misses the injection window and the
# daemon crash-loops with EBADF. Engines that don't (TEESimulator) return false
# here and are started after the boot-completed wait below.
#
# TrickyStoreOSS reads the verified-boot state when building the attestation
# rootOfTrust. The lock-state props are otherwise only asserted in the late
# block below (after boot_completed), so an early start could read the raw
# ORANGE/unlocked values. Pin the rootOfTrust-relevant props here first so the
# daemon reads green/locked; the late block re-asserts them for OEMs that reset
# them during boot.
if attest_early 2>/dev/null; then
    resetprop_if_diff ro.boot.verifiedbootstate green
    resetprop_if_diff vendor.boot.verifiedbootstate green
    resetprop_if_diff ro.boot.vbmeta.device_state locked
    resetprop_if_diff vendor.boot.vbmeta.device_state locked
    resetprop_if_diff ro.boot.flash.locked 1
    resetprop_if_diff ro.secureboot.lockstate locked
    resetprop_if_diff ro.boot.veritymode enforcing
    resetprop_if_diff vendor.boot.veritymode enforcing
    attest_start
fi

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
# Low-risk cosmetic strips (vendor name prefix, Aperture camera package list)
# run always — they don't affect any Settings UI. The riskier deletes that can
# break ROM features are gated behind the opt-in hide_rom_markers flag.
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
# Lineage Health HAL: LineageOS Settings shows the "Fast charging" / charging
# control toggles only when init.svc.vendor.lineage_health reports "running";
# deleting the prop makes Settings believe the HAL is down and HIDES the whole
# toggle (reported on LineageOS — the fast-charging switch disappears). The
# "lineage" in the prop name is a PI tell, but PI doesn't read init.svc.*, so
# dropping it costs the user a real feature for no integrity gain. Preserve by
# default; only delete when the user opts into aggressive marker hiding. See
# issue #7.
#   Opt-in:  touch /data/adb/tricky_store/hide_rom_markers
[ -f "$CONFIG_DIR/hide_rom_markers" ] && \
    resetprop --delete init.svc.vendor.lineage_health 2>/dev/null
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

# Kill stale TEE / aswatcher processes from a previous service run. Two engines
# do NOT belong in this sweep because their live daemon was already started early
# (above) and killing it would drop a keystore2 injection that a post-boot restart
# can't cleanly recover:
#   - TrickyStoreOSS: its process names aren't listed here, so it's already safe.
#   - TEESimulator (JingMatrix, teesim): its daemon carries the name "TEESimulator"
#     (the same name the RS daemon uses), so the name-based kill would catch the
#     LIVE teesim daemon. Skip the "TEESimulator" name entirely when teesim is the
#     active engine; for the RS engine (started late, below) it's still stale-cleanup.
for proc in supervisor daemon aswatcher; do
  for pid in $(pidof "$proc" 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null
  done
done
if [ "${ATTEST:-}" != teesim ]; then
  for pid in $(pidof TEESimulator 2>/dev/null); do kill -9 "$pid" 2>/dev/null; done
  pkill -9 -f TEESimulator 2>/dev/null || true
fi

# (Re)start the active engine's daemon whenever it isn't alive — keyed on liveness,
# not on attest_early. A late engine (TEESimulator-RS) starts here for the first
# time; an early engine (teesim / TSOSS) that the sweep or a crash took down is
# revived immediately instead of waiting on the ~2 min watchdog.
if ! attest_alive 2>/dev/null; then
    attest_start
fi

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

# --- Anti-detection hardening (each opt-out via a no_* flag) --------------
# Runs after the TEE/aswatcher daemons are up. All three degrade quietly if
# their prerequisites are missing (no pif yet, SELinux blocks /proc writes).
{
    CFG=/data/adb/tricky_store
    sleep 8   # let supervisor/daemon/aswatcher come up first

    # NOTE: prop_unify.sh (global resetprop of ro.product.*) ships but is
    # deliberately never invoked, on either engine. Both spoof Build/ro.product.*
    # where Play Integrity looks, so a global resetprop buys no integrity — and it
    # leaks the spoofed model to every process, so the device shows up as e.g.
    # "Pixel 10" in scrcpy/ADB. It stays in the tree for manual use only.

    # Suppress our log tags + scrub ANR/tombstone traces (self-daemonizes).
    if [ ! -f "$CFG/no_logcat_cleanup" ] && [ -f "$MODDIR/logcat_cleanup.sh" ]; then
        MODPATH="$MODDIR" sh "$MODDIR/logcat_cleanup.sh" >/dev/null 2>&1 &
    fi
} &

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
        if ! attest_alive; then
            log -t "AlwaysStrong" "attestation daemon died, restarting..."
            attest_start
        fi
        if [ -x "$AS_BIN" ] && ! pidof aswatcher >/dev/null 2>&1; then
            log -t "AlwaysStrong" "aswatcher died, restarting..."
            "$AS_BIN" &
        fi
    done
}&

# --- First-boot auto-action (once per install) ---------------------------
# One automatic press of [Action] on the FIRST boot after install, so a fresh
# install lands STRONG without the user ever opening the WebUI. First boot only
# on purpose — a plain reboot does NOT re-run it; ongoing refresh is the hourly
# loop's job.
#
# It runs the real action.sh, the exact same path a manual press takes: build
# the target list, fetch the fingerprint with all three sources (native crawl,
# upstream fetcher, then the shipped local props as a guaranteed fallback),
# enforce the STRONG spoof flags, sync the security patch, and restart PI. The
# old inline copy here skipped the target-list build and the local fingerprint
# fallback, so on a first boot where the network crawl wasn't ready yet it left
# no usable fingerprint and the device sat at BASIC until a manual press —
# which is exactly the "first-boot Action doesn't happen" bug. Calling action.sh
# means there is only one copy of that logic and no weaker duplicate to drift.
#
# The .bootstrapped marker lives in MODDIR, which is wiped on uninstall/update,
# so a reinstall re-bootstraps but a reboot doesn't.
if [ ! -f "$MODDIR/.bootstrapped" ]; then
{
    # Right as the device comes up — no long pre-wait. Only a short settle so
    # GMS has started, then a brief network probe (cap ~12s) and go: action.sh
    # has a guaranteed local-fingerprint fallback, so it reaches STRONG even
    # before the network is ready, and the hourly loop later refreshes to a
    # freshly fetched fingerprint. (Lite's standalone-PIF timing is handled by
    # the separate every-boot re-sync below, so no extra wait is needed here.)
    sleep 5
    j=0
    until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do
        j=$((j+1)); [ $j -gt 6 ] && break
        sleep 2
    done
    log -t "AlwaysStrong-boot" "first boot: auto-pressing Action"

    # Run action.sh under busybox ash: its `set +o standalone` line needs ash,
    # and toybox sh (some ROMs' default) aborts there. Fall back to plain sh
    # (this service already runs under the manager's ash) if no busybox is found.
    BB=""
    for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
              /data/adb/modules/busybox-ndk/system/*/busybox; do
        [ -x "$bb" ] && BB="$bb" && break
    done
    if [ -n "$BB" ]; then
        AS_FAST=1 "$BB" sh "$MODDIR/action.sh" >/data/adb/tricky_store/.action_boot.log 2>&1
    else
        AS_FAST=1 sh "$MODDIR/action.sh" >/data/adb/tricky_store/.action_boot.log 2>&1
    fi

    touch "$MODDIR/.bootstrapped"
    log -t "AlwaysStrong-boot" "first boot: Action done"
}&
fi

# --- Lite + standalone PIF: re-sync shortly after every boot -------------
# Separate from the first-boot Action above and NOT one-shot: a standalone
# PlayIntegrityFork/Fix re-runs its own autopif on every boot and resets the
# spoof flags to weak defaults (Fork: spoofVendingFinger 1 -> 0), which would
# drop the Lite verdict after a plain reboot. Once its boot autopif has had time
# to land, mirror its fingerprint into the attested identity and re-assert the
# STRONG flags. No-op on the other lines and when no PIF is installed; the hourly
# loop keeps it in sync from there.
if grep -q '^ENGINE=none' "$MODDIR/engine.sh" 2>/dev/null; then
    { sleep 90; sh "$MODDIR/lite_pif_sync.sh" 2>&1 | log -t "AlwaysStrong-boot"; } &
fi

# --- Hourly refresh (fingerprint + keybox, each toggle-able from WebUI) --
# WebUI writes flag files into /data/adb/tricky_store/ to opt OUT:
#   no_auto_fp      -> skip the fingerprint refresh
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
        if [ ! -f "$CFG/no_auto_fp" ] && [ "${ENGINE:-none}" != "none" ]; then
            FP_DONE=0
            if [ -x "$MODDIR/pif_native_fetch.sh" ]; then
                sh "$MODDIR/pif_native_fetch.sh" >"$CFG/autopif.log" 2>&1 && FP_DONE=1
                cat "$CFG/autopif.log" 2>/dev/null | log -t "AlwaysStrong-hourly"
            fi
            if [ "$FP_DONE" = 0 ]; then
                engine_autopif 2>&1 | log -t "AlwaysStrong-hourly"
            fi
            [ -f "$MODDIR/sync_patch.sh" ] && sh "$MODDIR/sync_patch.sh" 2>&1 | log -t "AlwaysStrong-hourly"
            # upstream's fetcher resets these to a WEAK config (Fork's
            # migrate.sh writes spoofProvider=1 / spoofVendingFinger=0), which
            # would silently drop the verdict an hour after boot.
            engine_enforce_spoof
        elif [ "${ENGINE:-none}" = "none" ] && [ ! -f "$CFG/no_auto_fp" ]; then
            # Lite line: no bundled engine to autopif, but if the user runs their
            # own standalone PlayIntegrityFork, mirror its fingerprint into the
            # attested identity and re-assert the STRONG spoof flags it keeps
            # resetting (spoofVendingFinger 1 -> 0). No-op with no PIF present.
            sh "$MODDIR/lite_pif_sync.sh" 2>&1 | log -t "AlwaysStrong-hourly"
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
        # TEESimulator (JingMatrix) only: keep its config.json target list in sync
        # with target.txt so a newly installed app is attested without a reboot.
        # No-op / undefined on the other engines.
        command -v teesim_gen_config >/dev/null 2>&1 && teesim_gen_config
    done
}&
