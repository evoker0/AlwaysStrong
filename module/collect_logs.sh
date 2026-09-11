#!/system/bin/sh
# AlwaysStrong — log collector.
#
# Dumps a diagnostic bundle to /sdcard so a user can attach it to a GitHub
# issue. Deliberately does NOT include the keybox contents (it holds private
# keys) — only its name, size and hash. The spoofed Pixel fingerprint IS
# included: it is fake by design and is exactly what a support request needs.
#
# Run it three ways:
#   - the "Collect logs" button in the WebUI (KSU / APatch / the standalone app)
#   - sh /data/adb/modules/tricky_store/collect_logs.sh   (root shell)
#   - sh action.sh logs
#
# Prints the output path on the last line so callers can show it.

MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd)
# fall back to the install path if run from a copy elsewhere (so the Module
# section isn't blank when someone runs the script from /sdcard or /tmp)
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/tricky_store
CFG=/data/adb/tricky_store
KEY_HOST="${KEYBOX_BASE_URL:-http://evoker.qzz.io}"

# Timestamped filename so repeated collections don't overwrite each other. If
# date is somehow unavailable, fall back to a fixed name.
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null)
[ -n "$STAMP" ] && OUT="/sdcard/AlwaysStrong-log-$STAMP.txt" || OUT="/sdcard/AlwaysStrong-log.txt"

# busybox for the tools toybox may lack (sha256sum on old devices, etc.)
BB=""
for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
          /data/adb/modules/busybox-ndk/system/*/busybox; do
    [ -x "$bb" ] && BB="$bb" && break
done
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; elif [ -n "$BB" ]; then "$BB" sha256sum; else echo "n/a"; fi; }

# asfetch, the same native fetcher the module uses — the one that fails on some
# ROMs, so it's exactly what we want to test here.
case "$(uname -m)" in
    aarch64) ABI=arm64-v8a ;; armv7*|armv8l) ABI=armeabi-v7a ;;
    x86_64) ABI=x86_64 ;; i?86) ABI=x86 ;; *) ABI="" ;;
esac
ASFETCH="$MODDIR/bin/$ABI/asfetch"

sec() { echo ""; echo "===== $* ====="; }

{
echo "AlwaysStrong diagnostic log"
echo "generated: $(date 2>/dev/null)"

sec "Module"
grep -E '^(name|version|versionCode)=' "$MODDIR/module.prop" 2>/dev/null
[ -f "$MODDIR/engine.sh" ] && grep -E '^ENGINE(_NAME)?=' "$MODDIR/engine.sh"

sec "Device / ROM"
for p in ro.product.brand ro.product.model ro.product.device \
         ro.build.version.release ro.build.version.sdk ro.product.first_api_level \
         ro.build.fingerprint ro.build.type ro.build.tags \
         ro.build.version.security_patch ro.product.cpu.abi ro.product.cpu.abilist; do
    echo "$p=$(getprop $p)"
done

# The BASIC verdict is DroidGuard's environment check, not attestation. These
# are the props it (and every root detector) looks at first; a permissive
# SELinux, a debuggable build or an orange boot state fails BASIC no matter how
# good the keybox is. Values are read as the shell sees them, so a prop the
# module resets only inside GMS (spoofProps) still shows the raw ROM value here.
sec "Integrity blockers (BASIC fails on any of these)"
SE=$(getenforce 2>/dev/null)
[ -z "$SE" ] && { case "$(cat /sys/fs/selinux/enforce 2>/dev/null)" in 1) SE=Enforcing ;; 0) SE=Permissive ;; *) SE=unknown ;; esac; }
case "$SE" in
    Enforcing) echo "selinux: Enforcing" ;;
    Permissive) echo "selinux: PERMISSIVE  <-- Play Integrity can NOT pass while SELinux is permissive; fix the ROM/kernel first" ;;
    *) echo "selinux: $SE (could not read)" ;;
esac
for p in ro.boot.verifiedbootstate ro.boot.flash.locked ro.boot.vbmeta.device_state \
         ro.boot.veritymode ro.debuggable ro.secure ro.adb.secure; do
    echo "$p=$(getprop $p)"
done

sec "Root manager / Zygisk"
echo "KSU: $([ -d /data/adb/ksu ] && echo yes || echo no)"
echo "APatch: $([ -d /data/adb/ap ] && echo yes || echo no)"
if [ -d /data/adb/magisk ]; then
    echo "Magisk: yes ($(magisk -v 2>/dev/null || echo 'version n/a'), code $(magisk -V 2>/dev/null || echo n/a))"
    # Built-in Zygisk must be OFF when Zygisk Next / ReZygisk provides it.
    echo "magisk builtin zygisk: $(magisk --sqlite "select value from settings where key='zygisk'" 2>/dev/null | sed 's/.*value=//' | grep . || echo unknown)"
    # PlayIntegrityFork wants GMS *out* of the denylist (it handles the unstable
    # process itself); the enforce toggle and the two Google entries are what
    # matter, so list only those.
    if magisk --denylist status >/dev/null 2>&1; then echo "denylist enforced: yes"; else echo "denylist enforced: no"; fi
    echo "denylist google entries: $(magisk --denylist ls 2>/dev/null | grep -E 'com.google.android.gms|com.android.vending' | tr '\n' ' ' | grep . || echo none)"
else
    echo "Magisk: no"
fi
echo "ZygiskNext: $([ -d /data/adb/modules/zygisksu ] && echo yes || echo no)"
echo "ReZygisk: $([ -d /data/adb/modules/rezygisk ] && echo yes || echo no)"

sec "Google apps"
for pkg in com.google.android.gms com.android.vending; do
    v=$(dumpsys package "$pkg" 2>/dev/null | grep -m1 versionName | sed 's/^[[:space:]]*versionName=//')
    echo "$pkg: ${v:-not found}"
done

sec "TEE / daemon processes"
# The daemon file is only a launcher: it execs into app_process under the engine's
# own process name, so it never shows up as "daemon" itself. Report the engine's
# real process name (from attest.sh) instead of a misleading "daemon: not running".
ATTEST=""; [ -f "$MODDIR/attest.sh" ] && . "$MODDIR/attest.sh" 2>/dev/null
case "$ATTEST" in
    trickystoreoss) ENGINE_PROC=TrickyStoreOSS ;;
    teesim)         ENGINE_PROC=teesim ;;
    *)              ENGINE_PROC=TEESimulator ;;
esac
echo "attestation engine: ${ATTEST_NAME:-TEESimulator-RS} (process: $ENGINE_PROC)"
for proc in "$ENGINE_PROC" supervisor aswatcher; do
    echo "$proc: $(pidof "$proc" 2>/dev/null || echo 'not running')"
done
if command -v attest_alive >/dev/null 2>&1; then
    attest_alive && echo "engine alive (attest_alive): yes" || echo "engine alive (attest_alive): NO"
fi

sec "Spoofed fingerprint (pif.prop — safe to share)"
for f in "$CFG/pif.prop" "$MODDIR/pif.prop" "$MODDIR/custom.pif.prop"; do
    [ -s "$f" ] && { echo "--- $f"; cat "$f"; break; }
done

sec "Keybox (metadata only — contents withheld)"
KB="$CFG/keybox.xml"
if [ -s "$KB" ]; then
    echo "path: $KB"
    echo "size: $(wc -c < "$KB") bytes"
    echo "sha256: $(sha < "$KB" | awk '{print $1}')"
    echo "looks-like-keybox: $(head -c 4096 "$KB" | grep -q Keybox && echo yes || echo NO)"
    echo "custom-keybox mode: $([ -f "$CFG/custom_keybox" ] && echo on || echo off)"
else
    echo "no keybox.xml present"
fi

sec "Target list (count + first 15)"
if [ -s "$CFG/target.txt" ]; then
    echo "apps: $(grep -cvE '^[[:space:]]*$' "$CFG/target.txt")"
    grep -vE '^[[:space:]]*$' "$CFG/target.txt" | head -15
else
    echo "no target.txt"
fi

sec "Config dir"
ls -l "$CFG" 2>/dev/null

sec "Network (most keybox/fingerprint failures are here)"
# raw IP reachability — no DNS involved
for ip in 1.1.1.1 8.8.8.8; do
    if ping -c1 -W2 "$ip" >/dev/null 2>&1; then echo "ping $ip: ok"; else echo "ping $ip: FAIL"; fi
done
# DNS: can the keybox host be resolved? Resolver often comes up late on some
# AOSP ROMs, which is what leaves them with no keybox on first boot.
HOST=$(echo "$KEY_HOST" | sed -e 's#^[a-z]*://##' -e 's#/.*##' -e 's#:.*##')
if command -v getent >/dev/null 2>&1 && getent hosts "$HOST" >/dev/null 2>&1; then
    echo "dns $HOST: ok ($(getent hosts "$HOST" | awk '{print $1}' | tr '\n' ' '))"
elif [ -n "$BB" ] && "$BB" nslookup "$HOST" >/dev/null 2>&1; then
    echo "dns $HOST: ok (via nslookup)"
else
    echo "dns $HOST: FAIL — cannot resolve (resolver not up / blocked)"
fi
# actual keybox fetch, one attempt per engine, with timing — shows which
# downloader works on this ROM and how long it takes.
NT="$CFG/.netcheck.$$"; mkdir -p "$NT"; trap 'rm -rf "$NT"' EXIT INT TERM
test_engine() {
    _name="$1"; shift
    _t0=$(date +%s 2>/dev/null)
    rm -f "$NT/out"
    "$@" >/dev/null 2>&1
    _t1=$(date +%s 2>/dev/null)
    if [ -s "$NT/out" ]; then
        echo "$_name: ok ($(wc -c < "$NT/out") bytes, ~$((_t1 - _t0))s)"
    else
        echo "$_name: FAIL (~$((_t1 - _t0))s)"
    fi
}
KURL="$KEY_HOST/key"
# short timeouts: this is a reachability probe, not the real fetch, and long
# per-engine stalls are what made pressing the button feel like a freeze.
[ -n "$ABI" ] && [ -x "$ASFETCH" ] && test_engine "asfetch    $KURL" "$ASFETCH" -T 5 -o "$NT/out" "$KURL" || echo "asfetch: not available for $ABI"
[ -n "$BB" ] && test_engine "busybox-wget" "$BB" wget -q -T 5 -O "$NT/out" "$KURL"
command -v curl >/dev/null 2>&1 && test_engine "curl       " curl -fsSL --connect-timeout 5 --max-time 8 -o "$NT/out" "$KURL"
command -v wget >/dev/null 2>&1 && test_engine "wget       " wget -q -T 5 -O "$NT/out" "$KURL"
echo "last-good engine (cached): $(cat "$CFG/.kb_engine" 2>/dev/null || echo none)"
rm -rf "$NT"; trap - EXIT INT TERM

sec "autopif.log (fingerprint fetch)"
cat "$CFG/autopif.log" 2>/dev/null | tail -40 || echo "none"

sec "Conflicting modules present"
for c in playintegrityfix playintegrityfork tricky_store_v2 TrickyStore \
         tee_simulator TEESimulator safetynet-fix MagiskHidePropsConf Yurikey; do
    [ -d "/data/adb/modules/$c" ] && echo "present: $c"
done

sec "logcat (our tags, last 200 lines)"
# -t 3000 reads only the tail of the ring buffer; a full `logcat -d` dump can be
# tens of MB and takes seconds, which is most of the button's perceived lag.
# PIF/Native + PIF/Java are PlayIntegrityFork's tags, plain "PIF" is inject-s;
# their presence is the only proof the spoof actually landed inside GMS.
logcat -d -t 3000 2>/dev/null | grep -iE 'AlwaysStrong|TEESimulator|tricky_store|aswatcher|libinject|PlayIntegrity|[^A-Za-z]PIF[/: ]' | tail -200 || echo "logcat unavailable"

sec "dmesg (our tags)"
dmesg 2>/dev/null | grep -iE 'TEESimulator|tricky_store|aswatcher' | tail -40 || echo "dmesg unavailable"

echo ""
echo "===== end ====="
} > "$OUT" 2>&1

chmod 664 "$OUT" 2>/dev/null
# leave a pointer to the newest log so the WebUI can launch this detached (no UI
# freeze) and poll for the path instead of waiting on the whole run.
echo "$OUT" > "$CFG/.last_log" 2>/dev/null
echo "$OUT"
