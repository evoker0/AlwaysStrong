#!/system/bin/sh
# AlwaysStrong — keep the security patch level consistent across:
#   1. /data/adb/tricky_store/security_patch.txt  — the patch level TEESimulator
#      stamps into the keystore hardware attestation. If this is missing or
#      stale the verdict drops to DEVICE even with a good keybox.
#   2. ro.build.version.security_patch system props — what Build.VERSION and
#      most app-side patch checks read.
#
# Source of truth: the SECURITY_PATCH=YYYY-MM-DD line from the active pif file
# (produced by autopif4). Falls back to the live system prop if no pif yet.
#
# Usage:
#   sh sync_patch.sh         # write security_patch.txt only (install / action)
#   sh sync_patch.sh boot    # also resetprop the system props (post-fs-data)

case "$0" in
    */*) MODPATH=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
    *)   MODPATH="$PWD" ;;
esac
[ -z "$MODPATH" ] && MODPATH="$PWD"
CONFIG_DIR=/data/adb/tricky_store
MODE="${1:-}"

# --- find the dotted patch (YYYY-MM-DD) from a pif file -------------------
SP=""
SRC=""
for f in "$CONFIG_DIR/custom.pif.prop" "$CONFIG_DIR/pif.prop" \
         "$MODPATH/custom.pif.prop" "$MODPATH/pif.prop"; do
    [ -s "$f" ] || continue
    SP=$(grep -m1 '^SECURITY_PATCH=' "$f" | cut -d= -f2- | tr -d ' "'\''\r')
    [ -n "$SP" ] && { SRC="$f"; break; }
done

# Feed TEESimulator's PatchLevelManager its expected PIF prop at the global
# path it watches (/data/adb/pif.prop). It auto-derives the attestation patch
# level + resetprops ro.build.version.security_patch from this file, keeping
# the keystore attestation in lock-step with the Build/* fingerprint PIF
# spoofs. (The module-folder path it also checks no longer exists by design.)
if [ -n "$SRC" ] && [ "$SRC" != "/data/adb/pif.prop" ]; then
    cp -f "$SRC" /data/adb/pif.prop 2>/dev/null && chmod 644 /data/adb/pif.prop 2>/dev/null
fi
# fall back to whatever the device already reports
[ -z "$SP" ] && SP=$(getprop ro.build.version.security_patch 2>/dev/null)
[ -z "$SP" ] && exit 1

# normalise: RAW = 8 digits, DOT = YYYY-MM-DD, PACKED = YYYYMMDD
RAW=$(echo "$SP" | tr -cd '0-9')
[ ${#RAW} -ne 8 ] && exit 1
PACKED="$RAW"
DOT="$(echo "$RAW" | cut -c1-4)-$(echo "$RAW" | cut -c5-6)-$(echo "$RAW" | cut -c7-8)"

mkdir -p "$CONFIG_DIR"

# --- 1. TEE attestation patch level (TrickyStore / TEESimulator-RS) --------
# `all=<YYYY-MM-DD>` overrides every partition's patch level in the generated
# attestation chain. Dotted form matches what autopif4 writes and what the
# working reference module ships, so the two never fight over format.
printf 'all=%s\n' "$DOT" > "$CONFIG_DIR/security_patch.txt"

# --- 2. PIF wildcard prop: spoof ro.build/ro.vendor/ro.system .security_patch
# A single `*.security_patch=<date>` line makes PIF's zygisk hook report the
# patch consistently to every app (this is what GMS / Play Integrity reads).
for pf in "$MODPATH/custom.pif.prop" "$CONFIG_DIR/custom.pif.prop"; do
    [ -f "$pf" ] || continue
    if grep -qE '^[#]?\*\.security_patch=' "$pf"; then
        sed -i "s|^[#]\?\*\.security_patch=.*|*.security_patch=$DOT|" "$pf"
    else
        printf '*.security_patch=%s\n' "$DOT" >> "$pf"
    fi
done

# --- 3. real system props (boot only — needs resetprop) -------------------
# Belt-and-suspenders for non-hooked readers (getprop, apps PIF doesn't hook).
# Only touch props that already exist so we don't invent phantom ones.
if [ "$MODE" = "boot" ] && command -v resetprop >/dev/null 2>&1; then
    for p in ro.build.version.security_patch \
             ro.vendor.build.security_patch \
             ro.system.build.version.security_patch; do
        cur=$(resetprop "$p" 2>/dev/null)
        [ -n "$cur" ] && [ "$cur" != "$DOT" ] && resetprop -n "$p" "$DOT"
    done
fi

echo "$DOT"
