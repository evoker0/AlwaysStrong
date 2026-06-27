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
[ -x "$MODPATH/keybox_fetch.sh" ] && \
    sh "$MODPATH/keybox_fetch.sh" >/dev/null 2>&1

# --- autopif4: fetch a fresh Pixel fingerprint from Google (silent) -------
FP_OK=1
[ -f "$MODPATH/autopif4.sh" ] && { sh "$MODPATH/autopif4.sh" -s -m >/dev/null 2>&1 || FP_OK=0; }

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
PATCH=""
[ -f "$MODPATH/sync_patch.sh" ] && PATCH=$(sh "$MODPATH/sync_patch.sh" 2>/dev/null)

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
# webroot natively from their own manager, so skip them. Stash a styled
# result line in WEBUI_MSG ("emoji|text") to print with the rest below.
WEBUI_MSG=""
if [ -d /data/adb/magisk ] && [ "$KSU" != "true" ] && [ "$APATCH" != "true" ]; then
    PKG=io.github.a13e300.ksuwebui
    if ! pm path "$PKG" >/dev/null 2>&1; then
        T=/data/local/tmp/.aswebui.apk
        API="https://api.github.com/repos/KOWX712/KsuWebUIStandalone/releases/latest"
        FB="https://github.com/KOWX712/KsuWebUIStandalone/releases/download/v1.0/KsuWebUI-1.0-48-release.apk"
        URL=$(dl_out "$API" 2>/dev/null | grep -o 'https://[^"]*\.apk' | head -1)
        [ -z "$URL" ] && URL="$FB"
        if dl_to "$T" "$URL" && [ -s "$T" ]; then
            chmod 644 "$T" 2>/dev/null
            if pm install -r "$T" >/dev/null 2>&1; then
                WEBUI_MSG="📲|WebUI app installed"
            else
                WEBUI_MSG="⚠️|WebUI install failed"
            fi
        else
            WEBUI_MSG="⚠️|WebUI download failed (offline?)"
        fi
        rm -f "$T" 2>/dev/null
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
