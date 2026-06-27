#!/system/bin/sh
# AlwaysStrong action button.
# Refreshes fingerprint (autopif4), enforces STRONG settings, syncs security
# patch, then restarts PI consumers. Runs the whole chain silently and prints
# one clean, framed summary: device, security patch, fingerprint, keybox.

case "$0" in
    */*) MODPATH=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
    *)   MODPATH="$PWD" ;;
esac
[ -z "$MODPATH" ] && MODPATH="$PWD"
cd "$MODPATH" 2>/dev/null

# disable busybox ash standalone mode — must run in current shell, not subshell
set +o standalone 2>/dev/null
unset ASH_STANDALONE

CONFIG_DIR=/data/adb/tricky_store
LINE="━━━━━━━━━━━━━━━━━━━━━━━━━"
VER=$(grep -m1 '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2-)

# one consistent row style for every line (success or failure)
row() { echo "    $1   $2"; }

echo ""
echo "  $LINE"
row "🛡️" "AlwaysStrong  ${VER}"
echo "  $LINE"
echo ""
row "⏳" "initializing, please wait"
echo "  $LINE"

# --- target.txt + keybox (silent) ----------------------------------------
# build_target_txt rewrites target.txt every tap: all user apps (pm -3) +
# installed OEM wallet/store apps + forced GMS/GSF/Vending. Count what landed.
[ -x "$MODPATH/build_target_txt.sh" ] && \
    sh "$MODPATH/build_target_txt.sh" "$CONFIG_DIR/target.txt" >/dev/null 2>&1
TGT_N=$(grep -cvE '^[[:space:]]*$' "$CONFIG_DIR/target.txt" 2>/dev/null)
# Keybox: if we already hold a valid one, refresh it in the BACKGROUND so a
# slow or unreachable mirror can't stall the Action (some networks reach
# Google fine but not the keybox host). With no keybox yet, fetch synchronously
# (still bounded by keybox_fetch's own wget timeout) because STRONG needs it now.
if [ -x "$MODPATH/keybox_fetch.sh" ]; then
    if [ -s "$CONFIG_DIR/keybox.xml" ] && head -c 4096 "$CONFIG_DIR/keybox.xml" | grep -q "Keybox"; then
        sh "$MODPATH/keybox_fetch.sh" >/dev/null 2>&1 &
    else
        sh "$MODPATH/keybox_fetch.sh" >/dev/null 2>&1
    fi
fi

# --- autopif4: fetch a fresh Pixel fingerprint from Google ----------------
# autopif4 pulls the latest Pixel build from several Google hosts (developer.
# android.com, flash.android.com, content-flashstation-pa.googleapis.com, ...)
# and exits non-zero if ANY single one fails — that is exactly what shows up
# as "fingerprint cached (offline?)". Bound it with a timeout so a stalled
# connection can't freeze the Action, retry once for transient failures, and
# keep the real output in CONFIG_DIR/autopif.log (instead of /dev/null) so an
# "offline" result is actually diagnosable.
FP_OK=1
if [ -f "$MODPATH/autopif4.sh" ]; then
    run_autopif() {
        if command -v timeout >/dev/null 2>&1; then
            timeout 60 sh "$MODPATH/autopif4.sh" -s -m
        else
            sh "$MODPATH/autopif4.sh" -s -m
        fi
    }
    run_autopif >"$CONFIG_DIR/autopif.log" 2>&1 \
        || { sleep 2; run_autopif >>"$CONFIG_DIR/autopif.log" 2>&1 || FP_OK=0; }
fi

# --- enforce STRONG-friendly spoof settings on every pif variant ----------
for f in "$MODPATH/custom.pif.prop" "$MODPATH/pif.prop" \
         "$CONFIG_DIR/custom.pif.prop" "$CONFIG_DIR/pif.prop"; do
    [ -f "$f" ] || continue
    for kv in spoofProvider=0 spoofVendingFinger=1 spoofBuild=1 \
              spoofProps=1 spoofSignature=0 spoofVendingSdk=0; do
        k="${kv%=*}"; v="${kv#*=}"
        if grep -qE "^${k}=" "$f"; then
            sed -i "s|^${k}=.*|${k}=${v}|" "$f"
        else
            echo "${k}=${v}" >> "$f"
        fi
    done
done

# --- sync security patch (attestation + Build) ---------------------------
# Pass "boot" so this ALSO resetprops ro.build.version.security_patch (and the
# vendor/system variants) to match the spoofed fingerprint. Without it the raw
# system prop only gets refreshed at boot, so after an Action-driven fingerprint
# bump the TEE patch (security_patch.txt) moves ahead while the system prop stays
# at the device's real patch — an inconsistency that both looks like "patch not
# updating" and can weaken the STRONG verdict. resetprop is available (root) in
# the Action context, same as post-fs-data.
PATCH=""
[ -f "$MODPATH/sync_patch.sh" ] && PATCH=$(sh "$MODPATH/sync_patch.sh" boot 2>/dev/null)

# --- WebUI: Magisk only → fetch KsuWebUI from GitHub if absent (silent) ----
dl_out() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 20 "$1"
    elif [ -x /data/adb/magisk/busybox ]; then /data/adb/magisk/busybox wget -q -T 20 -O - "$1"
    elif command -v wget >/dev/null 2>&1; then wget -q -T 20 -O - "$1"
    else return 1; fi
}
dl_to() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 60 -o "$1" "$2"
    elif [ -x /data/adb/magisk/busybox ]; then /data/adb/magisk/busybox wget -q -T 60 -O "$1" "$2"
    elif command -v wget >/dev/null 2>&1; then wget -q -T 60 -O "$1" "$2"
    else return 1; fi
}
# Only Magisk needs the standalone WebUI app. KSU/KSU-Next/APatch host the
# webroot natively from their own manager, so skip them. The APK download used
# to run inline, which blocked the Action button for up to a minute on Magisk
# on every tap the app wasn't installed yet. Do it in the BACKGROUND so the
# summary prints immediately; a lock file keeps repeated taps from stacking
# downloads, and a stale lock (tap that never finished) is cleared after 5 min.
WEBUI_MSG=""
if [ -d /data/adb/magisk ] && [ "$KSU" != "true" ] && [ "$APATCH" != "true" ]; then
    PKG=io.github.a13e300.ksuwebui
    [ -n "$(find "$MODPATH/.webui_busy" -mmin +5 2>/dev/null)" ] && rm -f "$MODPATH/.webui_busy" 2>/dev/null
    if ! pm path "$PKG" >/dev/null 2>&1 && [ ! -f "$MODPATH/.webui_busy" ]; then
        WEBUI_MSG="📲|installing WebUI app (background)"
        : > "$MODPATH/.webui_busy"
        {
            T=/data/local/tmp/.aswebui.apk
            API="https://api.github.com/repos/KOWX712/KsuWebUIStandalone/releases/latest"
            FB="https://github.com/KOWX712/KsuWebUIStandalone/releases/download/v1.0/KsuWebUI-1.0-48-release.apk"
            URL=$(dl_out "$API" 2>/dev/null | grep -o 'https://[^"]*\.apk' | head -1)
            [ -z "$URL" ] && URL="$FB"
            if dl_to "$T" "$URL" && [ -s "$T" ]; then
                chmod 644 "$T" 2>/dev/null
                pm install -r "$T" >/dev/null 2>&1
            fi
            rm -f "$T" "$MODPATH/.webui_busy" 2>/dev/null
        } &
    fi
fi

# --- restart PI (silent) -------------------------------------------------
killall -9 com.google.android.gms.unstable 2>/dev/null
killall -9 com.android.vending 2>/dev/null
am force-stop com.android.vending >/dev/null 2>&1

# --- update module.prop status indicator ---------------------------------
if [ -x "$MODPATH/status_fetch.sh" ]; then
    MODPATH="$MODPATH" sh "$MODPATH/status_fetch.sh" manual >/dev/null 2>&1
fi

# --- summary -------------------------------------------------------------
pick_pif() {
    for f in "$CONFIG_DIR/custom.pif.prop" "$MODPATH/custom.pif.prop" \
             "$CONFIG_DIR/pif.prop" "$MODPATH/pif.prop"; do
        [ -s "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}
PIF=$(pick_pif)
MD=$(grep -m1 '^MODEL=' "$PIF" 2>/dev/null | cut -d= -f2-)
[ -z "$PATCH" ] && PATCH=$(grep -m1 '^SECURITY_PATCH=' "$PIF" 2>/dev/null | cut -d= -f2-)

row "📱" "${MD:-unknown}"
row "🗓️" "${PATCH:-unknown}"

if [ "$FP_OK" = 1 ]; then
    row "🌐" "fingerprint fresh"
else
    row "⚠️" "fingerprint cached (offline?)"
fi

KB="$CONFIG_DIR/keybox.xml"
if [ -s "$KB" ] && head -c 4096 "$KB" | grep -q "Keybox"; then
    row "🔑" "keybox ok"
else
    row "⚠️" "keybox missing"
fi

[ -n "$TGT_N" ] && row "🎯" "${TGT_N} apps → target"

[ -n "$WEBUI_MSG" ] && row "${WEBUI_MSG%%|*}" "${WEBUI_MSG#*|}"

echo "  $LINE"
row "✅" "done"
echo "  $LINE"
echo ""
row "📣" "@keyboxstrong"
row "📣" "@evokeroot"
row "👤" "@evokerr"
echo "  $LINE"
echo ""

if { [ "$KSU" = "true" ] || [ "$APATCH" = "true" ]; } \
   && [ "$KSU_NEXT" != "true" ] && [ "$WKSU" != "true" ] && [ "$MMRL" != "true" ]; then
    sleep 2
fi
