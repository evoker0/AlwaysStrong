#!/system/bin/sh
# Lite line + a standalone Play Integrity Fix/Fork — keep the two in lock-step. The
# Lite build ships no PIF of its own; the user's separate module does the Build
# spoof, and this keystore module does the attestation. Three things drift apart on
# their own and this pulls them back together:
#
#   1. The PIF's autopif re-writes its custom.pif.prop on every fetch / Action and
#      resets the spoof flags to weak defaults (Fork: spoofVendingFinger 1 -> 0;
#      inject-s: spoofVendingBuild true -> false). We re-assert the STRONG flags,
#      honouring per-key spoof.conf overrides. The vending-finger/-build flag
#      follows the device's real Android version (off on 10-12L).
#   2. The keystore engine attests whatever is in /data/adb/tricky_store/pif.prop.
#      Left alone that goes stale while the PIF spoofs a newer Pixel into Build, so
#      the attested device stops matching Build. We mirror the PIF's fingerprint
#      into pif.prop so the attestation always reports the device the PIF spoofs.
#   3. sync_patch (attestation patch level) and, on -TEESIM, the teesim config are
#      regenerated from that fingerprint, then the PIF is restarted.
#
# The module id `playintegrityfix` is shared: osm0sis PlayIntegrityFork, chiteroman/
# KOWX712 PlayIntegrityFix inject-s, AND squatters like MeowDump's Integrity Box all
# use it. We ONLY sync the two real Fix/Fork variants (told apart for their differing
# flag names); anything else is left completely alone. Prints the kind on success
# ("OK fork" / "OK inject") so callers can report it; silent no-op otherwise.

MODDIR=${0%/*}; [ "$MODDIR" = "$0" ] && MODDIR=/data/adb/modules/tricky_store
CONFIG_DIR=/data/adb/tricky_store
PIF_DIR=/data/adb/modules/playintegrityfix

# Lite only, with a live module actually present.
grep -q '^ENGINE=none' "$MODDIR/engine.sh" 2>/dev/null || exit 0
[ -d "$PIF_DIR" ] && [ ! -f "$PIF_DIR/disable" ] && [ ! -f "$PIF_DIR/remove" ] || exit 0

# --- identify the module: only real PlayIntegrityFork / Fix inject-s qualify ---
_mp="$PIF_DIR/module.prop"
_id="$(grep -m1 '^name=' "$_mp" 2>/dev/null)$(grep -m1 '^updateJson=' "$_mp" 2>/dev/null)$(grep -m1 '^author=' "$_mp" 2>/dev/null)"
PIF_KIND=""
# Integrity Box (MeowDump) & co. squat the shared `playintegrityfix` id but are
# NOT a real Fix/Fork we may touch. Reject them via a FULL module.prop scan — the
# `webuiIcon=` tell lives on its own line, not among the name/updateJson/author
# fields that _id samples, so a case on _id alone would miss it (matching the
# sibling scanners in customize.sh / conflict_scan.sh).
if grep -qiE 'MeowDump|ntegrity.?[Bb]ox|webuiIcon' "$_mp" 2>/dev/null; then
    PIF_KIND=""
else
    case "$_id" in
        *Fork*|*osm0sis/PlayIntegrityFork*)        PIF_KIND="fork" ;;         # PlayIntegrityFork
        *Fix*|*[Ii]nject*|*chiteroman*|*KOWX712*)  PIF_KIND="inject" ;;       # PlayIntegrityFix inject-s
    esac
fi
# Must also actually be a Build-spoof PIF: a zygisk dir + a fingerprint to mirror.
[ -n "$PIF_KIND" ] && [ -d "$PIF_DIR/zygisk" ] || exit 0
# The active prop is whichever one actually carries the FINGERPRINT — Fork keeps it
# in custom.pif.prop, inject-s in pif.prop (custom.pif.prop is only an override).
SRC=""
for _c in "$PIF_DIR/custom.pif.prop" "$PIF_DIR/pif.prop"; do
    [ -s "$_c" ] && grep -q '^FINGERPRINT=' "$_c" 2>/dev/null && { SRC="$_c"; break; }
done
[ -n "$SRC" ] || exit 0

# --detect: just report the recognised kind (fork|inject) and touch nothing. The
# WebUI uses this to decide whether to show the spoof controls without restarting
# GMS on every page load; the real sync runs at boot / hourly / Action / on a toggle.
[ "$1" = "--detect" ] && { echo "$PIF_KIND"; exit 0; }

# sed -i: prefer a busybox with real in-place support.
BB=""
for bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox \
          "$(command -v busybox 2>/dev/null)"; do
    [ -n "$bb" ] && [ -x "$bb" ] && BB="$bb" && break
done
SED_I="sed -i"; [ -n "$BB" ] && SED_I="$BB sed -i"

# --- 1. spoof flags: FORK ONLY --------------------------------------------
# PlayIntegrityFork's autopif keeps resetting spoofVendingFinger 1 -> 0, so we
# re-assert the STRONG Fork flags (version-aware, honouring spoof.conf overrides
# set in our WebUI). PlayIntegrityFix inject-s is left untouched: it ships its own
# full WebUI and the user manages spoofBuild / spoofProps / spoofVendingBuild there,
# so we only mirror its fingerprint below and never fight its settings.
if [ "$PIF_KIND" = fork ]; then
    _svf=1
    _sdk=$(getprop ro.build.version.sdk 2>/dev/null)
    case "$_sdk" in ''|*[!0-9]*) : ;; *) [ "$_sdk" -le 32 ] && _svf=0 ;; esac
    for _kv in "spoofProvider=0" "spoofVendingFinger=$_svf" "spoofBuild=1" "spoofProps=1" "spoofSignature=0" "spoofVendingSdk=0"; do
        _k=${_kv%%=*}; _v=${_kv#*=}
        _o=$(sed -n "s/^$_k=//p" "$CONFIG_DIR/spoof.conf" 2>/dev/null | head -1 | tr -d ' \t\r')
        [ -n "$_o" ] && _v="$_o"
        if grep -q "^$_k=" "$SRC"; then $SED_I "s|^$_k=.*|$_k=$_v|" "$SRC"; else echo "$_k=$_v" >> "$SRC"; fi
    done
else
    # inject-s owns its own flags via its own WebUI. Don't enforce a default set —
    # only push the flags the user explicitly changed in OUR Advanced tab (each lands
    # in spoof.conf) onto its prop, leaving everything else exactly as inject-s set it.
    if [ -s "$CONFIG_DIR/spoof.conf" ]; then
        while IFS='=' read -r _k _v || [ -n "$_k" ]; do
            case "$_k" in ''|'#'*|*[!A-Za-z0-9_]*) continue ;; esac
            _v=$(printf '%s' "$_v" | tr -d ' \t\r')
            [ -n "$_v" ] || continue
            if grep -q "^$_k=" "$SRC"; then $SED_I "s|^$_k=.*|$_k=$_v|" "$SRC"; else echo "$_k=$_v" >> "$SRC"; fi
        done < "$CONFIG_DIR/spoof.conf"
    fi
fi

# --- 2. mirror the PIF fingerprint into the engine's identity source --------
cp -f "$SRC" "$CONFIG_DIR/pif.prop" 2>/dev/null
chmod 600 "$CONFIG_DIR/pif.prop" 2>/dev/null

# --- 3. patch level + teesim config from the fresh fingerprint --------------
[ -f "$MODDIR/sync_patch.sh" ] && sh "$MODDIR/sync_patch.sh" >/dev/null 2>&1
if [ -f "$MODDIR/attest.sh" ]; then
    . "$MODDIR/attest.sh"
    command -v teesim_gen_config >/dev/null 2>&1 && teesim_gen_config
fi

# --- 4. restart the PIF so Build reflects the re-asserted flags -------------
if [ -f "$PIF_DIR/killpi.sh" ]; then
    sh "$PIF_DIR/killpi.sh" >/dev/null 2>&1
else
    killall -9 com.google.android.gms.unstable 2>/dev/null
fi
echo "OK $PIF_KIND"
