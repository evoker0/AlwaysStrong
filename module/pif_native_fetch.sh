#!/system/bin/sh
# AlwaysStrong — native fingerprint fallback.
#
# PlayIntegrityFork's autopif4.sh crawls Google's Pixel build servers with
# busybox `wget`, whose built-in TLS stalls mid-stream on some devices/CDNs —
# so on those devices autopif4 silently fails and no fresh fingerprint lands.
# This script replays the SAME crawl (developer.android.com → flash.android.com
# → content-flashstation-pa.googleapis.com → source.android.com) but drives it
# with our statically-linked rustls fetcher (asfetch), which speaks TLS 1.2/1.3
# correctly everywhere. curl / busybox wget are used only if asfetch is absent.
#
# On success it writes a minimal Pixel Canary pif.prop to $CONFIG_DIR/pif.prop
# (same file the shipped static fallback in action.sh uses) and exits 0.
# Any failure exits non-zero and leaves the existing pif untouched.
#
# Exit codes:
#   0  fresh fingerprint written
#   1  crawl/parse failed (nothing written)

CONFIG_DIR=/data/adb/tricky_store
TARGET="$CONFIG_DIR/pif.prop"
TIMEOUT=10

log() { echo "pif_native_fetch: $*"; }

# ---- Resolve the module dir + asfetch binary ----
SELF_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR=/data/adb/modules/tricky_store
case "$(uname -m)" in
    aarch64)        ABI=arm64-v8a ;;
    armv7*|armv8l)  ABI=armeabi-v7a ;;
    x86_64)         ABI=x86_64 ;;
    i?86)           ABI=x86 ;;
    *)              ABI="" ;;
esac
ASFETCH="$SELF_DIR/bin/$ABI/asfetch"

BB=""
for p in /data/adb/modules/busybox-ndk/system/*/busybox /data/adb/magisk/busybox \
         /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    [ -f "$p" ] && BB="$p" && break
done

if [ -z "$BB" ] && [ -z "$ABI" -o ! -x "$ASFETCH" ] \
   && ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    log "no fetcher available (asfetch/curl/wget)."; exit 1
fi

# fetch OUTFILE URL [REFERER]  — REFERER is required by the flashstation API,
# which is guarded by a referrer-restricted browser key. asfetch goes first (it
# connects IPv4-first, so it works on every device incl. IPv6-only-DNS networks);
# busybox wget / curl are fallbacks in case asfetch ever fails on a host.
fetch() {
    _o="$1"; _u="$2"; _ref="$3"
    if [ -n "$ABI" ] && [ -x "$ASFETCH" ]; then
        rm -f "$_o"
        if [ -n "$_ref" ]; then "$ASFETCH" -T "$TIMEOUT" -H "Referer: $_ref" -o "$_o" "$_u" 2>/dev/null
        else "$ASFETCH" -T "$TIMEOUT" -o "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    if [ -n "$BB" ]; then
        rm -f "$_o"
        if [ -n "$_ref" ]; then "$BB" wget -q -T "$TIMEOUT" --header "Referer: $_ref" --no-check-certificate -O "$_o" "$_u" 2>/dev/null
        else "$BB" wget -q -T "$TIMEOUT" --no-check-certificate -O "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        rm -f "$_o"
        if [ -n "$_ref" ]; then curl -fsSL --max-time "$TIMEOUT" -e "$_ref" -o "$_o" "$_u" 2>/dev/null
        else curl -fsSL --max-time "$TIMEOUT" -o "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        rm -f "$_o"
        if [ -n "$_ref" ]; then wget -q -T "$TIMEOUT" --header "Referer: $_ref" -O "$_o" "$_u" 2>/dev/null
        else wget -q -T "$TIMEOUT" -O "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    return 1
}

# Prefer busybox grep/tac: toybox's `grep -A` (context lines) is unreliable on
# some devices and returns nothing, which breaks the canary-block extraction.
# autopif4 guards against the same broken-toybox-grep behaviour.
if [ -n "$BB" ]; then GREP="$BB grep"; else GREP=grep; fi
reverse() { # portable `tac`
    if [ -n "$BB" ]; then "$BB" tac
    elif command -v tac >/dev/null 2>&1; then tac
    else sed '1!G;h;$!d'; fi
}

W="$CONFIG_DIR/.pif_native.$$"
mkdir -p "$W" || { log "cannot create work dir."; exit 1; }
trap 'rm -rf "$W"' EXIT INT TERM

# ---- 1. latest Pixel Beta device list (Android Developers) ----
fetch "$W/versions.html" "https://developer.android.com/about/versions" || {
    log "developer.android.com unreachable."; exit 1; }
LATEST_URL=$($GREP -o 'https://developer.android.com/about/versions/.*[0-9]"' "$W/versions.html" \
    | sort -ru | cut -d'"' -f1 | head -n1)
[ -z "$LATEST_URL" ] && { log "no latest version page found."; exit 1; }
fetch "$W/latest.html" "$LATEST_URL" || { log "version page fetch failed."; exit 1; }

FI_HREF=$($GREP -o 'href=".*download.*"' "$W/latest.html" | $GREP 'qpr' | cut -d'"' -f2 | head -n1)
OTA_HREF=$($GREP -o 'href=".*download-ota.*"' "$W/latest.html" | $GREP 'qpr' | cut -d'"' -f2 | head -n1)
[ -n "$FI_HREF" ]  && fetch "$W/fi.html"  "https://developer.android.com$FI_HREF"
[ -n "$OTA_HREF" ] && fetch "$W/ota.html" "https://developer.android.com$OTA_HREF"

# Pick whichever table (Factory Image vs OTA) lists more devices.
SRC=fi
[ -s "$W/fi.html" ] || SRC=ota
if [ -s "$W/fi.html" ] && [ -s "$W/ota.html" ]; then
    nfi=$($GREP -c 'tr id=' "$W/fi.html" 2>/dev/null)
    nota=$($GREP -c 'tr id=' "$W/ota.html" 2>/dev/null)
    [ "${nota:-0}" -gt "${nfi:-0}" ] && SRC=ota
fi
[ -s "$W/$SRC.html" ] || { log "no device table."; exit 1; }

MODEL_LIST=$($GREP -A1 'tr id=' "$W/$SRC.html" | $GREP 'td' | sed 's;.*<td>\(.*\)</td>.*;\1;')
PRODUCT_LIST=$($GREP 'tr id=' "$W/$SRC.html" | sed 's;.*<tr id="\(.*\)">.*;\1_beta;')
[ -z "$PRODUCT_LIST" ] && { log "device list parse failed."; exit 1; }

# ---- 2. select device: prefer an exact match for THIS device, else random ----
MODEL=""; PRODUCT=""; DEVICE=""
THISDEV=$(getprop ro.product.device 2>/dev/null)
case " $(echo $PRODUCT_LIST) " in
    *" ${THISDEV}_beta "*)
        MODEL=$(getprop ro.product.model 2>/dev/null)
        PRODUCT="${THISDEV}_beta"
        DEVICE="$THISDEV"
        ;;
esac
if [ -z "$PRODUCT" ]; then
    N=$(echo "$PRODUCT_LIST" | grep -c .)
    [ "${N:-0}" -lt 1 ] && { log "empty device list."; exit 1; }
    R="${RANDOM:-$$}"
    IDX=$(( (R % N) + 1 ))
    MODEL=$(echo "$MODEL_LIST"   | sed -n "${IDX}p")
    PRODUCT=$(echo "$PRODUCT_LIST" | sed -n "${IDX}p")
    DEVICE=$(echo "$PRODUCT" | sed 's/_beta//')
fi
[ -z "$PRODUCT" ] || [ -z "$DEVICE" ] && { log "device selection failed."; exit 1; }
log "device: ${MODEL:-?} ($PRODUCT)"

# ---- 3. Android Flash Tool client key, then the Canary build JSON ----
fetch "$W/flash.html" "https://flash.android.com/" || { log "flash.android.com unreachable."; exit 1; }
KEY=$($GREP -o '<body data-client-config=.*' "$W/flash.html" | cut -d';' -f2 | cut -d'&' -f1)
[ -z "$KEY" ] && { log "flash client key not found."; exit 1; }

fetch "$W/station.json" \
    "https://content-flashstation-pa.googleapis.com/v1/builds?product=$PRODUCT&key=$KEY" \
    "https://flash.android.com" || { log "flashstation API unreachable."; exit 1; }

reverse < "$W/station.json" | $GREP -m1 -A13 '"canary": true' > "$W/canary.json"
ID=$($GREP 'releaseCandidateName' "$W/canary.json" | cut -d'"' -f4)
INCREMENTAL=$($GREP 'buildId' "$W/canary.json" | cut -d'"' -f4)
[ -z "$ID" ] || [ -z "$INCREMENTAL" ] && { log "canary build info missing from JSON."; exit 1; }

# ---- 4. security patch level from the Pixel Update Bulletins ----
CANARY_ID=$($GREP '"id"' "$W/canary.json" | sed -e 's;.*canary-\(.*\)".*;\1;' -e 's;^\(.\{4\}\);\1-;')
SECURITY_PATCH=""
if [ -n "$CANARY_ID" ]; then
    if fetch "$W/secbull.html" "https://source.android.com/docs/security/bulletin/pixel"; then
        SECURITY_PATCH=$($GREP "<td>$CANARY_ID" "$W/secbull.html" | sed 's;.*<td>\(.*\)</td>;\1;' | head -n1)
    fi
    # autopif4's own fallback: assume the -05 patch for the canary month.
    [ -z "$SECURITY_PATCH" ] && SECURITY_PATCH="${CANARY_ID}-05"
fi
[ -z "$SECURITY_PATCH" ] && SECURITY_PATCH="$(date '+%Y-%m')-05"

# ---- 5. emit pif.prop, then migrate -> custom.pif.prop (the file PIF reads) ----
# PIF's zygisk reads custom.pif.prop from the module dir, NOT pif.prop. Writing
# only pif.prop leaves PIF spoofing a stale/default fingerprint and STRONG fails.
# So we run the bundled migrate.sh exactly like autopif4 does. action.sh Step 4
# then enforces the STRONG spoof settings (spoofProvider=0, spoofVendingFinger=1…).
FP="google/$PRODUCT/$DEVICE:CANARY/$ID/$INCREMENTAL:user/release-keys"
TMP="$W/pif.prop"
cat > "$TMP" <<EOF
MANUFACTURER=Google
MODEL=$MODEL
FINGERPRINT=$FP
PRODUCT=$PRODUCT
DEVICE=$DEVICE
SECURITY_PATCH=$SECURITY_PATCH
DEVICE_INITIAL_SDK_INT=32
EOF

grep -q 'FINGERPRINT=google/.*/.*:CANARY/' "$TMP" || { log "produced pif.prop looks wrong."; exit 1; }

mkdir -p "$CONFIG_DIR"
cp -f "$TMP" "$TARGET" 2>/dev/null   # keep pif.prop for display + sync_patch

if [ ! -f "$SELF_DIR/migrate.sh" ]; then
    log "migrate.sh missing — PIF can't read pif.prop, aborting."; exit 1
fi
cp -f "$TMP" "$SELF_DIR/pif.prop" 2>/dev/null
rm -f "$SELF_DIR/custom.pif.prop" "$SELF_DIR/custom.pif.json" 2>/dev/null
sh "$SELF_DIR/migrate.sh" -i -a "$SELF_DIR/pif.prop" >/dev/null 2>&1
if [ ! -s "$SELF_DIR/custom.pif.prop" ]; then
    log "migrate.sh did not produce custom.pif.prop."; exit 1
fi

# migrate.sh defaults to spoofProvider=1 / spoofVendingFinger=0, which asks for
# a WEAK attestation and breaks STRONG. Enforce the STRONG settings here so the
# native path is correct no matter who calls it (boot, hourly, Action) — the
# hourly loop has no separate enforce step, so self-enforcing is essential.
for kv in spoofProvider=0 spoofVendingFinger=1 spoofBuild=1 \
          spoofProps=1 spoofSignature=0 spoofVendingSdk=0; do
    k="${kv%=*}"; v="${kv#*=}"
    if grep -qE "^${k}=" "$SELF_DIR/custom.pif.prop"; then
        sed -i "s|^${k}=.*|${k}=${v}|" "$SELF_DIR/custom.pif.prop"
    else
        echo "${k}=${v}" >> "$SELF_DIR/custom.pif.prop"
    fi
done

log "installed custom.pif.prop ($FP)"
exit 0
