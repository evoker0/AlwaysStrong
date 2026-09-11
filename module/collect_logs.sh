#!/system/bin/sh
# AlwaysStrong — log collector.
#
# Dumps a diagnostic bundle to /sdcard so a user can attach it to a GitHub
# issue. Deliberately does NOT include the keybox contents (it holds private
# keys) — only its name, size, hash and shape. The spoofed Pixel fingerprint IS
# included: it is fake by design and is exactly what a support request needs.
# Nothing here reads the serial, IMEI, Android ID or accounts; the teesim
# config.json identity fields are redacted. What the bundle does reveal is the
# list of targeted apps (target.txt), i.e. which banking apps are installed.
#
# Run it three ways:
#   - the "Collect logs" button in the WebUI (KSU / APatch / the standalone app)
#   - sh /data/adb/modules/tricky_store/collect_logs.sh   (root shell)
#   - sh action.sh logs
#
# Every network / IPC step is wall-clock bounded: the WebUI waits ~90 s for the
# output path, so a dead network must not turn the button into a hang.
#
# Prints the output path on the last line so callers can show it.

MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
# fall back to the install path if run from a copy elsewhere (so the Module
# section isn't blank when someone runs the script from /sdcard or /tmp)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/tricky_store
CFG=/data/adb/tricky_store
KEY_HOST="${KEYBOX_BASE_URL:-http://evoker.qzz.io}"

# Timestamped filename so repeated collections don't overwrite each other. If
# date is somehow unavailable, fall back to a fixed name. /sdcard can be
# unavailable (FBE still locked, work profile, unmounted) — fall back to the
# config dir rather than reporting a path that does not exist.
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null)
NAME="AlwaysStrong-log${STAMP:+-$STAMP}.txt"
OUT="/sdcard/$NAME"
( : > "$OUT" ) 2>/dev/null || OUT="$CFG/$NAME"

# busybox for the tools toybox may lack (sha256sum on old devices, etc.)
BB=""
for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
          /data/adb/modules/busybox-ndk/system/*/busybox; do
    [ -x "$bb" ] && BB="$bb" && break
done
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif [ -n "$BB" ]; then "$BB" sha256sum; else echo "n/a"; fi; }

# bounded SECS cmd... — hard wall-clock cap (same helper as keybox_fetch.sh).
# toybox timeout (Android 10+) and busybox timeout both take -k; -k SIGKILLs a
# command that ignores the SIGTERM, which a `sh` waiting on a child would defer.
TO=""
if timeout -k 1 5 true >/dev/null 2>&1; then TO="timeout -k 2"
elif timeout 5 true >/dev/null 2>&1; then TO="timeout"
elif [ -n "$BB" ] && "$BB" timeout -k 1 5 true >/dev/null 2>&1; then TO="$BB timeout -k 2"
elif [ -n "$BB" ] && "$BB" timeout 5 true >/dev/null 2>&1; then TO="$BB timeout"
fi
bounded() { _bs="$1"; shift; if [ -n "$TO" ]; then $TO "$_bs" "$@"; else "$@"; fi; }

# asfetch, the same native fetcher the module uses — the one that fails on some
# ROMs, so it's exactly what we want to test here.
case "$(uname -m)" in
    aarch64) ABI=arm64-v8a ;; armv7*|armv8l) ABI=armeabi-v7a ;;
    x86_64) ABI=x86_64 ;; i?86) ABI=x86 ;; *) ABI="" ;;
esac
ASFETCH="$MODDIR/bin/$ABI/asfetch"

sec() { echo ""; echo "===== $* ====="; }
props() { for p in "$@"; do echo "$p=$(getprop "$p" 2>/dev/null)"; done; }
# tail_or NAME FILE N — tail a file, or say it is missing/empty (a bare
# `cmd | tail || echo none` never fires: tail exits 0 on empty input).
tail_or() { if [ -s "$2" ]; then tail -n "$3" "$2"; else echo "$1: none"; fi; }

# Engine adapters. engine.sh (PIF side) and attest.sh (keystore side) define
# functions + a few variables and have no side effects when sourced; they tell
# us which prop file the zygisk really reads and which process is the engine.
MODPATH="$MODDIR"; CONFIG_DIR="$CFG"
ENGINE=""; ATTEST=""; ATTEST_NAME=""
[ -f "$MODDIR/engine.sh" ] && . "$MODDIR/engine.sh" 2>/dev/null
[ -f "$MODDIR/attest.sh" ] && . "$MODDIR/attest.sh" 2>/dev/null
# JingMatrix's App renames itself to "TEESimulator" too (overriding
# --nice-name=teesim), so both TEE engines show up under the same process name.
case "$ATTEST" in
    trickystoreoss) ENGINE_PROC=TrickyStoreOSS ;;
    *)              ENGINE_PROC=TEESimulator ;;
esac

{
echo "AlwaysStrong diagnostic log"
echo "generated: $(date 2>/dev/null)"

sec "Module"
grep -E '^(name|version|versionCode|description)=' "$MODDIR/module.prop" 2>/dev/null
echo "engine (PIF): ${ENGINE:-none}${ENGINE_NAME:+ ($ENGINE_NAME)}"
echo "engine (attestation): ${ATTEST:-?}${ATTEST_NAME:+ ($ATTEST_NAME)}"
for f in disable remove update skip_mount .bootstrapped skipdelprop skippersistprop; do
    [ -e "$MODDIR/$f" ] && echo "module flag: $f"
done
[ -d /data/adb/modules_update/tricky_store ] && echo "UPDATE PENDING in modules_update — reboot required"
echo "--- module dir (names only)"
ls -A "$MODDIR" 2>/dev/null | tr '\n' ' '; echo
for d in zygisk lib teesim bin; do
    [ -d "$MODDIR/$d" ] && echo "$d/: $(cd "$MODDIR/$d" 2>/dev/null && find . -type f 2>/dev/null | sed 's|^\./||' | tr '\n' ' ')"
done
# build.sh binary-patches PIF's zygisk lib to read its config from OUR module
# dir; an unpatched lib reads /data/adb/modules/playintegrityfix and spoofs nothing.
for so in "$MODDIR"/zygisk/*.so; do
    [ -f "$so" ] || continue
    if grep -aqF '/data/adb/modules/tricky_store' "$so"; then echo "${so##*/}: config path patched ok"
    else echo "${so##*/}: config path NOT patched (bad build)"; fi
done

sec "Device / ROM"
props ro.product.brand ro.product.model ro.product.device ro.product.vendor.name \
      ro.build.version.release ro.build.version.sdk ro.product.first_api_level \
      ro.build.fingerprint ro.build.id ro.build.display.id ro.build.version.incremental \
      ro.build.type ro.build.tags ro.build.date.utc \
      ro.build.version.security_patch ro.vendor.build.security_patch \
      ro.product.cpu.abi ro.product.cpu.abilist ro.boot.hardware ro.kernel.qemu \
      ro.lineage.version ro.modversion
echo "kernel: $(uname -r -m 2>/dev/null)"

# The BASIC verdict is DroidGuard's environment check, not attestation. These
# are the props it (and every root detector) looks at first; a permissive
# SELinux, a debuggable build or an orange boot state fails BASIC no matter how
# good the keybox is.
#
# NOTE: service.sh / post-fs-data.sh resetprop the ro.boot.* lock-state props to
# green/locked device-wide, so getprop shows the SPOOFED value. The kernel
# command line (androidboot.*) is the unspoofed truth — read both.
sec "Integrity blockers (BASIC fails on any of these)"
SE=$(getenforce 2>/dev/null)
[ -z "$SE" ] && { case "$(cat /sys/fs/selinux/enforce 2>/dev/null)" in 1) SE=Enforcing ;; 0) SE=Permissive ;; *) SE=unknown ;; esac; }
case "$SE" in
    Enforcing) echo "selinux: Enforcing" ;;
    Permissive) echo "selinux: PERMISSIVE  <-- Play Integrity can NOT pass while SELinux is permissive; fix the ROM/kernel first" ;;
    *) echo "selinux: $SE (could not read)" ;;
esac
echo "--- kernel cmdline (real boot state, not spoofable by resetprop)"
tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep -E '^androidboot\.(verifiedbootstate|vbmeta\.device_state|flash\.locked|veritymode|secureboot|selinux|warranty_bit|mode|bootmode)=' || echo "(no androidboot.* in cmdline)"
grep -E '^androidboot\.(verifiedbootstate|vbmeta\.device_state|flash\.locked|veritymode|selinux)' /proc/bootconfig 2>/dev/null
echo "--- props (as processes see them; ro.boot.* lock props are pinned by the module)"
props ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.vbmeta.device_state \
      ro.boot.veritymode ro.boot.vbmeta.digest ro.boot.verifiedbooterror \
      ro.boot.warranty_bit ro.is_ever_orange ro.debuggable ro.secure ro.adb.secure \
      ro.crypto.state ro.boot.mode ro.bootmode
echo "--- clock (a wrong clock breaks TLS to the mirror and attestation validity)"
echo "utc: $(date -u 2>/dev/null)  epoch: $(date +%s 2>/dev/null)  build.date.utc: $(getprop ro.build.date.utc)  tz: $(getprop persist.sys.timezone)"
[ "$(date +%s 2>/dev/null || echo 0)" -lt "$(getprop ro.build.date.utc 2>/dev/null || echo 0)" ] 2>/dev/null && echo "CLOCK IS BEHIND THE ROM BUILD DATE"
echo "uptime: $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s  boot_completed: $(getprop sys.boot_completed)"

sec "Root manager / Zygisk"
echo "KSU: $([ -d /data/adb/ksu ] && echo yes || echo no)$([ -x /data/adb/ksud ] && echo " ($(bounded 3 /data/adb/ksud -V 2>/dev/null | head -1))")"
echo "APatch: $([ -d /data/adb/ap ] && echo yes || echo no)$([ -x /data/adb/apd ] && echo " ($(bounded 3 /data/adb/apd -V 2>/dev/null | head -1))")"
if [ -d /data/adb/magisk ]; then
    echo "Magisk: yes ($(bounded 3 magisk -v 2>/dev/null || echo 'version n/a'), code $(bounded 3 magisk -V 2>/dev/null || echo n/a))"
    # Built-in Zygisk must be OFF when Zygisk Next / ReZygisk provides it.
    echo "magisk builtin zygisk: $(bounded 3 magisk --sqlite "select value from settings where key='zygisk'" 2>/dev/null | sed 's/.*value=//' | grep . || echo unknown)"
    # PlayIntegrityFork wants GMS *out* of the denylist (it handles the unstable
    # process itself); the enforce toggle and the two Google entries are what
    # matter, so list only those.
    if bounded 3 magisk --denylist status >/dev/null 2>&1; then echo "denylist enforced: yes"; else echo "denylist enforced: no"; fi
    echo "denylist google entries: $(bounded 3 magisk --denylist ls 2>/dev/null | grep -E 'com.google.android.gms|com.android.vending' | tr '\n' ' ' | grep . || echo none)"
else
    echo "Magisk: no"
fi
# Zygisk providers publish their live injection state in their own description.
for z in zygisksu rezygisk neozygisk; do
    [ -f "/data/adb/modules/$z/module.prop" ] && echo "$z: $(grep -m1 '^description=' "/data/adb/modules/$z/module.prop" | cut -d= -f2-)$([ -f "/data/adb/modules/$z/disable" ] && echo ' [DISABLED]')"
done
[ -d /data/adb/modules/zygisk_shamiko ] && echo "shamiko: present$([ -f /data/adb/shamiko/whitelist ] && echo ' (whitelist mode)')"
ls -d /data/adb/modules/*lsposed* /data/adb/lspd 2>/dev/null | sed 's/^/xposed: /'
echo "ptrace_scope: $(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo n/a)  (2/3 = injecting into keystore2 cannot work)"
echo "--- installed modules (state)"
for m in /data/adb/modules/*/; do
    n=${m%/}; n=${n##*/}; s=""
    [ -f "$m/disable" ] && s="$s DISABLED"; [ -f "$m/remove" ] && s="$s REMOVE"
    [ -f "$m/update" ] && s="$s update"; [ -d "$m/zygisk" ] && s="$s zygisk"
    echo "$n$s"
done

sec "Google apps"
for pkg in com.google.android.gms com.android.vending; do
    v=$(bounded 10 dumpsys package "$pkg" 2>/dev/null | grep -m1 versionName | sed 's/^[[:space:]]*versionName=//')
    echo "$pkg: ${v:-not found}"
done
echo "gms apk: $(bounded 8 pm path com.google.android.gms 2>/dev/null | head -1 | sed 's/^package://')"
# PIF/Native + PIF/Java are PlayIntegrityFork's tags, plain "PIF" is inject-s;
# these lines are the only proof the spoof landed inside GMS (the dex is loaded
# in-memory, so /proc/maps shows nothing). 0 = restart gms.unstable and re-collect.
echo "PIF lines in recent logcat: $(bounded 10 logcat -d -t 3000 2>/dev/null | grep -cE '[^A-Za-z]PIF[/: ]')"

sec "TEE / daemon processes"
# The daemon file is only a launcher: it execs into app_process under the engine's
# own process name, so it never shows up as "daemon" itself.
echo "attestation engine: ${ATTEST_NAME:-TEESimulator-RS} (process: $ENGINE_PROC)"
for proc in "$ENGINE_PROC" supervisor aswatcher; do
    echo "$proc: $(pidof "$proc" 2>/dev/null || echo 'not running')"
done
if command -v attest_alive >/dev/null 2>&1; then
    attest_alive 2>/dev/null && echo "engine alive (attest_alive): yes" || echo "engine alive (attest_alive): NO"
fi
KP=$(pidof keystore2 2>/dev/null); echo "keystore2 pid: ${KP:-NOT RUNNING}"
[ -n "$KP" ] && echo "injected into keystore2: $(grep -oE '[^ ]*(TEESimulator|TrickyStoreOSS|teesim|tricky_store|inject)[^ ]*' "/proc/$KP/maps" 2>/dev/null | sort -u | tr '\n' ' ' | grep . || echo 'NOTHING (engine lib not mapped)')"
echo "--- process ages (a keystore2 younger than the engine lost its injection)"
ps -A -o PID,ELAPSED,NAME 2>/dev/null | grep -E 'keystore2|TEESimulator|TrickyStoreOSS|teesim|supervisor|aswatcher|gms\.unstable|com\.android\.vending$' \
    || ps -A 2>/dev/null | grep -E 'keystore2|TEESimulator|TrickyStoreOSS|gms\.unstable'
getprop 2>/dev/null | grep -E '^\[(init\.svc\.keystore2|init\.svc\.[^]]*key(mint|master)[^]]*|ro\.hardware\.keystore[^]]*)\]'
case "$ATTEST" in
    teesim)
        echo "--- JingMatrix TEESimulator state"
        ls -la /data/adb/teesim 2>/dev/null
        echo "teesim keybox -> $(readlink /data/adb/teesim/keybox.xml 2>/dev/null || echo 'NOT a symlink')"
        [ -f /data/adb/teesim/config.json ] && sed -E 's/"(serial|imei|imei2|meid)": *"[^"]*"/"\1": "<redacted>"/' /data/adb/teesim/config.json
        echo "gms uid (packages.list): $(sed -n 's/^com\.google\.android\.gms \([0-9]*\) .*/\1/p' /data/system/packages.list 2>/dev/null | head -1)"
        L=$(cat "$CFG/.teesim_loop" 2>/dev/null); [ -n "$L" ] && echo "teesim loop pid $L alive: $(kill -0 "$L" 2>/dev/null && echo yes || echo NO)" ;;
    trickystoreoss)
        L=$(cat "$CFG/.ts_loop" 2>/dev/null); [ -n "$L" ] && echo "TSOSS loop pid $L alive: $(kill -0 "$L" 2>/dev/null && echo yes || echo NO)" ;;
esac

sec "Spoofed fingerprint (safe to share)"
# The engine adapter knows which prop file the zygisk really reads (Fork:
# custom.pif.prop in the module dir, inject-s: pif.prop). The copy in
# /data/adb/tricky_store is only for display — showing that one hid every
# "fetched but never landed" case. Hash every copy so a mismatch is visible.
echo "effective spoof flags (defaults + spoof.conf): $(engine_spoof_kv 2>/dev/null || echo n/a)"
ZP=""
for f in $(engine_pif_targets 2>/dev/null) "$CFG/pif.prop" /data/adb/pif.prop; do
    [ -f "$f" ] || continue
    [ -z "$ZP" ] && ZP="$f"
    echo "$(sha < "$f" | cut -c1-12)  $(stat -c '%y %s' "$f" 2>/dev/null)  $f"
done
if [ -n "$ZP" ] && [ -s "$ZP" ]; then echo "--- $ZP"; cat "$ZP"; else echo "no fingerprint prop file present"; fi
echo "--- spoof.conf (user overrides)"; if [ -s "$CFG/spoof.conf" ]; then cat "$CFG/spoof.conf"; else echo "none"; fi

sec "Security patch coherence (DEVICE-but-not-STRONG cause #1)"
echo "security_patch.txt: $(cat "$CFG/security_patch.txt" 2>/dev/null || echo MISSING)"
echo "fingerprint SECURITY_PATCH: $([ -n "$ZP" ] && sed -n 's/^SECURITY_PATCH=//p' "$ZP" | head -1)"
props ro.build.version.security_patch ro.vendor.build.security_patch ro.system.build.version.security_patch
echo "spoof patch props: $([ -f "$CFG/no_spoof_patch_props" ] && echo 'OFF (user opt-out)' || echo on)"

sec "Keybox (metadata only — contents withheld)"
KB="$CFG/keybox.xml"
if [ -s "$KB" ]; then
    echo "path: $KB"
    ls -l "$KB" 2>/dev/null
    echo "size: $(wc -c < "$KB") bytes"
    echo "sha256: $(sha < "$KB" | awk '{print $1}')"
    echo "looks-like-keybox: $(head -c 4096 "$KB" | grep -q Keybox && echo yes || echo NO)"
    echo "certs: $(grep -o '<Certificate' "$KB" | wc -l | tr -d " ")  privkeys: $(grep -o '<PrivateKey' "$KB" | wc -l | tr -d " ")  algos: $(grep -oE 'algorithm="[a-z]+"' "$KB" | sort -u | tr '\n' ' ') keyboxes: $(grep -oE '<NumberOfKeyboxes>[0-9]+' "$KB" | tr -dc '0-9')"
    echo "custom-keybox mode: $([ -f "$CFG/custom_keybox" ] && echo on || echo off)"
    echo "per-app keyboxes (names only): $(ls "$CFG"/*.xml 2>/dev/null | grep -v '/keybox.xml$' | sed 's|.*/||' | tr '\n' ' ' | grep . || echo none)"
else
    echo "no keybox.xml present"
fi

sec "Target list (count + first 15)"
if [ -s "$CFG/target.txt" ]; then
    echo "apps: $(grep -cvE '^[[:space:]]*$' "$CFG/target.txt")"
    grep -vE '^[[:space:]]*$' "$CFG/target.txt" | head -15
    # build_target_txt.sh forces these three; missing = the keybox never applies to GMS.
    echo "--- Play Integrity core entries"
    grep -nE '^(com\.google\.android\.gms|com\.android\.vending|com\.google\.android\.gsf)' "$CFG/target.txt" || echo "GMS/Vending/GSF NOT in target.txt"
    echo "per-app keybox sections: $(grep -c '^\[' "$CFG/target.txt")"
else
    echo "no target.txt"
fi

sec "Config dir"
ls -la "$CFG" 2>/dev/null
echo "--- WebUI flags (present = set)"
for f in no_auto_fp no_auto_keybox no_auto_indicator no_rom_spoof_block no_spoof_patch_props \
         spoof_patch_props custom_keybox hide_rom_markers no_logcat_cleanup no_prop_unify; do
    [ -f "$CFG/$f" ] && echo "$f: ON"
done
echo "hourly_interval_sec: $(cat "$CFG/hourly_interval_sec" 2>/dev/null || echo 'default 3600')"
echo "custom_packages: $(grep -cvE '^[[:space:]]*$' "$CFG/custom_packages" 2>/dev/null || echo 0)"

sec "Network (most keybox/fingerprint failures are here)"
# raw IP reachability — no DNS involved
for ip in 1.1.1.1 8.8.8.8; do
    if bounded 4 ping -c1 -W2 "$ip" >/dev/null 2>&1; then echo "ping $ip: ok"; else echo "ping $ip: FAIL"; fi
done
# DNS: can the keybox host be resolved? Resolver often comes up late on some
# AOSP ROMs, which is what leaves them with no keybox on first boot. (getent
# does not exist on Android; busybox nslookup has no timeout of its own.)
HOST=$(echo "$KEY_HOST" | sed -e 's#^[a-z]*://##' -e 's#/.*##' -e 's#:.*##')
if [ -n "$BB" ] && bounded 6 "$BB" nslookup "$HOST" >/dev/null 2>&1; then
    echo "dns $HOST: ok (via nslookup)"
elif bounded 6 ping -c1 -W2 "$HOST" >/dev/null 2>&1; then
    echo "dns $HOST: ok (via ping)"
else
    echo "dns $HOST: FAIL — cannot resolve (resolver not up / blocked)"
fi
# actual keybox fetch, one attempt per engine, with timing — shows which
# downloader works on this ROM and how long it takes. Each downloader's -T is
# an IDLE timeout, so the outer cap is what keeps a dead route from hanging us.
NT="$CFG/.netcheck.$$"; [ -d "$CFG" ] || NT="/data/local/tmp/.asnetcheck.$$"
mkdir -p "$NT"; trap 'rm -rf "$NT"' EXIT INT TERM
test_engine() {
    _name="$1"; shift
    _t0=$(date +%s 2>/dev/null)
    rm -f "$NT/out"
    bounded 8 "$@" >/dev/null 2>&1
    _t1=$(date +%s 2>/dev/null)
    if [ -s "$NT/out" ]; then
        echo "$_name: ok ($(wc -c < "$NT/out") bytes, ~$((_t1 - _t0))s)"
    else
        echo "$_name: FAIL (~$((_t1 - _t0))s)"
    fi
}
KURL="$KEY_HOST/key"
[ -n "$ABI" ] && [ -x "$ASFETCH" ] && test_engine "asfetch    $KURL" "$ASFETCH" -T 5 -o "$NT/out" "$KURL" || echo "asfetch: not available for $ABI"
[ -n "$BB" ] && test_engine "busybox-wget" "$BB" wget -q -T 5 -O "$NT/out" "$KURL"
command -v curl >/dev/null 2>&1 && test_engine "curl       " curl -fsSL --connect-timeout 5 --max-time 8 -o "$NT/out" "$KURL"
command -v wget >/dev/null 2>&1 && test_engine "wget       " wget -q -T 5 -O "$NT/out" "$KURL"
echo "last-good engine (cached): $(cat "$CFG/.kb_engine" 2>/dev/null || echo none)"
rm -rf "$NT"; trap - EXIT INT TERM

sec "Module logs on disk"
# logcat_cleanup.sh silences our own logcat tags at the source
# (persist.log.tag.AlwaysStrong*=S) unless no_logcat_cleanup exists, so the
# logcat section below normally has NO AlwaysStrong lines by design — the
# on-disk copies are where the boot / hourly / watchdog messages live.
for t in AlwaysStrong AlwaysStrong-boot AlwaysStrong-hourly; do echo "persist.log.tag.$t=$(getprop "persist.log.tag.$t")"; done
echo "--- autopif.log (fingerprint fetch)"; tail_or autopif.log "$CFG/autopif.log" 40
echo "--- .action_boot.log (first-boot Action)"; tail_or action_boot.log "$CFG/.action_boot.log" 60
echo "--- .action_reset.log (Reset to defaults)"; tail_or action_reset.log "$CFG/.action_reset.log" 40
echo "--- module.log"; tail_or module.log "$MODDIR/logs/module.log" 60

sec "SELinux denials / crashes around keystore"
# sepolicy.rule grants keystore access to /data/adb; a denial here means the
# rule was not applied and the engine cannot read the keybox.
bounded 8 dmesg 2>/dev/null | grep -E 'avc: *denied' | grep -E 'keystore|tricky_store|teesim|TEESimulator|TrickyStoreOSS|adb_data_file|shell_data_file|zygisk|app_process|ptrace' | tail -30
bounded 8 logcat -d -b crash -t 200 2>/dev/null | grep -iE 'keystore2|TEESimulator|TrickyStoreOSS|teesim|gms' | tail -30
echo "recent tombstones: $(ls -t /data/tombstones 2>/dev/null | head -3 | tr '\n' ' ' | grep . || echo none)"

sec "logcat (our tags, last 200 lines)"
# -t 3000 reads only the tail of the ring buffer; a full `logcat -d` dump can be
# tens of MB and takes seconds, which is most of the button's perceived lag.
# PIF/Native + PIF/Java are PlayIntegrityFork's tags, plain "PIF" is inject-s.
bounded 10 logcat -d -t 3000 2>/dev/null | grep -iE 'AlwaysStrong|TEESimulator|TrickyStoreOSS|tricky_store|aswatcher|libinject|PlayIntegrity|[^A-Za-z]PIF[/: ]' | tail -200

sec "dmesg (our tags)"
bounded 8 dmesg 2>/dev/null | grep -iE 'TEESimulator|TrickyStoreOSS|tricky_store|aswatcher' | tail -40

echo ""
echo "===== end ====="
} > "$OUT" 2>&1

chmod 664 "$OUT" 2>/dev/null
# leave a pointer to the newest log so the WebUI can launch this detached (no UI
# freeze) and poll for the path instead of waiting on the whole run.
echo "$OUT" > "$CFG/.last_log" 2>/dev/null
echo "$OUT"
