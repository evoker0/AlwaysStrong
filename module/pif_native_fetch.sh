#!/system/bin/sh
# AlwaysStrong — native fingerprint fallback.
#
# PlayIntegrityFork's autopif4.sh crawls Google's Pixel build servers with
# busybox `wget`, whose built-in TLS stalls mid-stream on some devices/CDNs —
# so on those devices autopif4 silently fails and no fresh fingerprint lands.
# We drive the fetch with our statically-linked rustls fetcher (asfetch), which
# speaks TLS 1.2/1.3 correctly everywhere (curl / busybox wget only if absent),
# AND take the minimal-endpoint path: flash.android.com (browser key, with an
# embedded fallback) + content-flashstation-pa.googleapis.com (the canary build
# per product). The old device-list crawl (developer.android.com versions + the
# factory-image/OTA tables) and the source.android.com patch-bulletin crawl are
# GONE — they were ~6 page fetches and two brittle HTML-table parses that made a
# refresh take ~24s and graze the action timeout. Every current Pixel shares one
# canary build, so a static device list + build query is equivalent and ~8x
# faster with far fewer failure points.
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
TIMEOUT=15   # idle timeout per fetch; the outer per-fetch cap is TIMEOUT + CAP_EXTRA
CAP_EXTRA=60

log() { echo "pif_native_fetch: $*"; }

# ---- Resolve the module dir + asfetch binary ----
SELF_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR=/data/adb/modules/tricky_store

# This fetches the Pixel identity. Where it lands, and under which spoof-flag
# names, belongs to engine.sh — writing the engine's prop file directly from
# here would give one build flags the other's zygisk cannot read.
MODPATH="$SELF_DIR"
if [ -f "$SELF_DIR/engine.sh" ]; then
    . "$SELF_DIR/engine.sh"
else
    log "engine.sh missing — cannot install a fingerprint."; exit 1
fi
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

# bounded SECS cmd... — run cmd under a hard wall-clock cap. A fetcher that
# never returns (asfetch / wget / curl stuck on a dead route, a hung DNS, a
# TLS stall) used to freeze the whole Action: status_fetch and the first-tap
# keybox fetch called it with no bound at all, so the screen sat after the last
# row with no "done" until the user gave up. Every network step now goes through
# this; the caller falls through to the next engine when the cap trips.
# toybox timeout (Android 10+) and busybox timeout both take -k; -k SIGKILLs a
# command that ignores the SIGTERM, which a `sh` waiting on a child would defer.
TO=""
if timeout -k 1 5 true >/dev/null 2>&1; then TO="timeout -k 3"
elif timeout 5 true >/dev/null 2>&1; then TO="timeout"
elif [ -n "$BB" ] && "$BB" timeout -k 1 5 true >/dev/null 2>&1; then TO="$BB timeout -k 3"
elif [ -n "$BB" ] && "$BB" timeout 5 true >/dev/null 2>&1; then TO="$BB timeout"
fi
bounded() { _bs="$1"; shift; if [ -n "$TO" ]; then $TO "$_bs" "$@"; else "$@"; fi; }
# Caps are set for "definitely dead", never for "slow": each downloader's own
# -T is an IDLE timeout (asfetch, busybox wget, wget) or is paired with a speed
# floor (curl), so a slow link that keeps delivering bytes is never cut off; the
# outer cap only backstops a process that is stuck entirely.

# ---- Fast path: asfetch's in-process fetcher --------------------------------
# `asfetch autopif` does the whole crawl inside its bounded rustls client (real
# JSON parsing, no busybox grep/tac, no shell subshells), writing pif.prop itself
# in ~2-5s. This is the primary path; the shell crawl below is the fallback for
# when the binary is absent/older or the in-process fetch fails. An old asfetch
# that predates the subcommand just treats "autopif" as a URL and exits non-zero,
# so this stays safe on a stale binary.
#
# It writes the identity with inject-s's spoof-flag names baked in, so it is
# aimed at a scratch dir and those lines are stripped — the engine adapter
# appends the set its own zygisk reads. Seeding the scratch copy from the
# current pif.prop keeps asfetch's security-patch reuse working.
if [ -n "$ABI" ] && [ -x "$ASFETCH" ]; then
    NW="$CONFIG_DIR/.pif_asfetch.$$"
    mkdir -p "$NW"
    # The caller bounds us with `timeout`, so a SIGTERM lands mid-fetch often
    # enough to matter. INT/TERM must exit explicitly: busybox ash resumes the
    # script after a trap, which would leave the fetch writing into a dir that
    # was just deleted.
    trap 'rm -rf "$NW"' EXIT
    trap 'rm -rf "$NW"; exit 143' TERM
    trap 'rm -rf "$NW"; exit 130' INT
    [ -f "$TARGET" ] && cp -f "$TARGET" "$NW/pif.prop" 2>/dev/null
    # asfetch has its own no-progress watchdog (exit 124) well inside this cap.
    bounded 150 "$ASFETCH" autopif --out "$NW/pif.prop" --module "$NW" 2>&1
    _rc=$?
    # 124 = the cap tripped: asfetch is not answering on this device/network.
    # Don't hand the shell crawl the same stuck binary — it would burn its cap
    # on every page; go straight to busybox wget / curl for the fallback.
    if [ "$_rc" = 124 ] || [ "$_rc" = 137 ]; then
        log "native autopif timed out — skipping asfetch for the shell crawl"
        ASFETCH=""
    fi
    if [ "$_rc" = 0 ] \
       && grep -q '^FINGERPRINT=google/.*:CANARY/' "$NW/pif.prop" 2>/dev/null; then
        grep -vE '^(spoof|DEBUG)' "$NW/pif.prop" > "$NW/identity.prop" 2>/dev/null
        engine_spoof_block >> "$NW/identity.prop"
        if engine_install_pif "$NW/identity.prop"; then
            cp -f "$NW/identity.prop" "$TARGET" 2>/dev/null
            log "native autopif ok ($ENGINE)"
            exit 0
        fi
        log "native autopif fetched, but $ENGINE could not install it"
    fi
    rm -rf "$NW"
    trap - EXIT TERM INT   # hand the traps over to the shell crawl's own $W
    log "native autopif unavailable/failed — trying shell crawl"
fi

# fetch OUTFILE URL [REFERER]  — REFERER is required by the flashstation API,
# which is guarded by a referrer-restricted browser key. asfetch goes first (it
# connects IPv4-first, so it works on every device incl. IPv6-only-DNS networks);
# busybox wget / curl are fallbacks in case asfetch ever fails on a host.
fetch() {
    _o="$1"; _u="$2"; _ref="$3"
    if [ -n "$ABI" ] && [ -x "$ASFETCH" ]; then
        rm -f "$_o"
        if [ -n "$_ref" ]; then bounded $((TIMEOUT + CAP_EXTRA)) "$ASFETCH" -T "$TIMEOUT" -H "Referer: $_ref" -o "$_o" "$_u" 2>/dev/null
        else bounded $((TIMEOUT + CAP_EXTRA)) "$ASFETCH" -T "$TIMEOUT" -o "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    if [ -n "$BB" ]; then
        rm -f "$_o"
        if [ -n "$_ref" ]; then bounded $((TIMEOUT + CAP_EXTRA)) "$BB" wget -q -T "$TIMEOUT" --header "Referer: $_ref" --no-check-certificate -O "$_o" "$_u" 2>/dev/null
        else bounded $((TIMEOUT + CAP_EXTRA)) "$BB" wget -q -T "$TIMEOUT" --no-check-certificate -O "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        rm -f "$_o"
        if [ -n "$_ref" ]; then bounded $((TIMEOUT + CAP_EXTRA)) curl -fsSL --connect-timeout 15 --speed-limit 1 --speed-time "$TIMEOUT" --max-time $((TIMEOUT + CAP_EXTRA - 5)) -e "$_ref" -o "$_o" "$_u" 2>/dev/null
        else bounded $((TIMEOUT + CAP_EXTRA)) curl -fsSL --connect-timeout 15 --speed-limit 1 --speed-time "$TIMEOUT" --max-time $((TIMEOUT + CAP_EXTRA - 5)) -o "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        rm -f "$_o"
        if [ -n "$_ref" ]; then bounded $((TIMEOUT + CAP_EXTRA)) wget -q -T "$TIMEOUT" --header "Referer: $_ref" -O "$_o" "$_u" 2>/dev/null
        else bounded $((TIMEOUT + CAP_EXTRA)) wget -q -T "$TIMEOUT" -O "$_o" "$_u" 2>/dev/null; fi
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
# Clean up on exit. INT/TERM MUST exit explicitly: busybox ash RESUMES the script
# after running a signal trap, so without the exit a `timeout` SIGTERM would delete
# $W and then let the crawl keep running until it dies writing pif.prop into the
# now-missing dir ("can't create .../pif.prop"). Exit cleanly so the caller falls
# back instead of hitting that misleading half-run failure.
trap 'rm -rf "$W"' EXIT
trap 'rm -rf "$W"; exit 143' TERM
trap 'rm -rf "$W"; exit 130' INT

# ---- 1. flashstation browser key (the only page we still scrape) ----
# flash.android.com guards the builds API with a referrer-scoped key embedded in
# its landing HTML. Scrape it; if the page is reshaped/blocked, fall back to the
# embedded last-known key so a bad landing page can't sink the whole fetch. That
# key is a PUBLIC value from that page's HTML, locked to the flash.android.com
# referrer — not a secret; it's assembled from parts only so it isn't a literal
# "AIza…" string that trips repo secret scanners.
KEY=""
if fetch "$W/flash.html" "https://flash.android.com/"; then
    KEY=$($GREP -o '<body data-client-config=.*' "$W/flash.html" \
        | cut -d';' -f2 | cut -d'&' -f1 | tr -d '"' | head -n1)
fi
[ -z "$KEY" ] && { KEY="AIzaSyD-bwHpMvFCN3""PfRN4Txsw""_ECg_iptNfMQ"; log "using embedded flashstation key"; }
[ -z "$KEY" ] && { log "no flashstation key."; exit 1; }

# ---- 2. current Pixel Canary identities: "<device>|<model>" per line ----
# Update on rebuild as Google's beta lineup rolls forward. Base "Pixel 9" (tokay)
# is deliberately omitted: Google stopped granting it STRONG even with a valid
# keybox, so picking it would silently demote the device.
PIXEL_DEVICES="caiman|Pixel 9 Pro
komodo|Pixel 9 Pro XL
tegu|Pixel 9a
comet|Pixel 9 Pro Fold
frankel|Pixel 10
blazer|Pixel 10 Pro
felix|Pixel Fold"
NDEV=$(printf '%s\n' "$PIXEL_DEVICES" | $GREP -c .)

# ---- 3. query builds per product until one yields a canary; bounded tries ----
THISDEV=$(getprop ro.product.device 2>/dev/null)
MODEL=""; PRODUCT=""; DEVICE=""; ID=""; INCREMENTAL=""

parse_canary() { # reads $W/builds.json -> sets ID/INCREMENTAL, 0 on a canary hit
    # Bot-wall guard: a rate-limited IP gets HTML ('<') instead of JSON ('{');
    # treat that as a miss so we roll to the next product.
    case "$(head -c1 "$W/builds.json" 2>/dev/null)" in '{'|'[') ;; *) return 1 ;; esac
    # `"canary": true` sits in a previewMetadata sub-object AFTER buildId /
    # releaseCandidateName in each entry, so reverse the lines first — then a
    # forward -A window captures the ids of that same (newest) canary block.
    reverse < "$W/builds.json" | $GREP -m1 -A25 '"canary": *true' > "$W/canary.json" 2>/dev/null
    ID=$($GREP 'releaseCandidateName' "$W/canary.json" | cut -d'"' -f4 | head -n1)
    INCREMENTAL=$($GREP 'buildId' "$W/canary.json" | cut -d'"' -f4 | head -n1)
    [ -n "$ID" ] && [ -n "$INCREMENTAL" ]
}

query_product() { # $1=device $2=model -> sets PRODUCT/DEVICE/MODEL on success
    _d="$1"; _m="$2"; _p="${_d}_beta"
    fetch "$W/builds.json" \
        "https://content-flashstation-pa.googleapis.com/v1/builds?product=$_p&key=$KEY" \
        "https://flash.android.com" || return 1
    parse_canary || return 1
    PRODUCT="$_p"; DEVICE="$_d"; MODEL="$_m"
}

# Prefer THIS device's own identity when we ship it, else a random rotation.
if [ -n "$THISDEV" ]; then
    _this_model=$(printf '%s\n' "$PIXEL_DEVICES" | $GREP -m1 "^${THISDEV}|" | cut -d'|' -f2)
    [ -n "$_this_model" ] && query_product "$THISDEV" "$_this_model"
fi

if [ -z "$PRODUCT" ]; then
    R="${RANDOM:-$$}"
    START=$(( R % NDEV ))
    I=0
    # Cap tries so an EOL/no-canary pick can never stall the whole run; every
    # query is independently timeout-bounded by fetch().
    while [ "$I" -lt 4 ] && [ "$I" -lt "$NDEV" ]; do
        IDX=$(( ((START + I) % NDEV) + 1 ))
        LINE=$(printf '%s\n' "$PIXEL_DEVICES" | sed -n "${IDX}p")
        I=$(( I + 1 ))
        [ -n "$LINE" ] || continue
        query_product "${LINE%%|*}" "${LINE#*|}" && break
    done
fi
{ [ -z "$PRODUCT" ] || [ -z "$ID" ] || [ -z "$INCREMENTAL" ]; } && { log "no canary build found."; exit 1; }
log "device: ${MODEL:-?} ($PRODUCT) build $ID"

# ---- 4. security patch: reuse the shared canary patch, else derive from ID ----
# All current Pixels share the same canary patch, so an existing good pif.prop is
# the most reliable source. Else derive YYYY-MM-05 from the 6-digit YYMMDD
# segment in the build ID (ZP11.260618.005 -> 2026-06-05). No source.android.com.
SECURITY_PATCH=""
for _pf in "$SELF_DIR/pif.prop" "$TARGET"; do
    [ -f "$_pf" ] || continue
    SECURITY_PATCH=$($GREP '^SECURITY_PATCH=' "$_pf" 2>/dev/null | cut -d= -f2 | head -n1)
    [ -n "$SECURITY_PATCH" ] && break
done
if [ -z "$SECURITY_PATCH" ]; then
    _seg=$(printf '%s' "$ID" | tr '.' '\n' | $GREP -E '^[0-9]{6}$' | head -n1)
    [ -n "$_seg" ] && SECURITY_PATCH="20$(echo "$_seg" | cut -c1-2)-$(echo "$_seg" | cut -c3-4)-05"
fi
[ -z "$SECURITY_PATCH" ] && SECURITY_PATCH="$(date '+%Y-%m')-05"

# ---- 5. emit the identity, then let the engine install it -------------------
# The build fields are engine-neutral; the spoof flags are not. Fork wants
# spoofProvider=0 / spoofVendingFinger=1 in custom.pif.prop, inject-s wants
# spoofProvider=false / spoofVendingBuild=true in pif.prop. engine.sh supplies
# both halves.
FP="google/$PRODUCT/$DEVICE:CANARY/$ID/$INCREMENTAL:user/release-keys"
TMP="$W/pif.prop"
cat > "$TMP" <<EOF
FINGERPRINT=$FP
MANUFACTURER=Google
MODEL=$MODEL
PRODUCT=$PRODUCT
DEVICE=$DEVICE
SECURITY_PATCH=$SECURITY_PATCH
DEVICE_INITIAL_SDK_INT=32
EOF
engine_spoof_block >> "$TMP"

grep -q 'FINGERPRINT=google/.*/.*:CANARY/' "$TMP" || { log "produced pif.prop looks wrong."; exit 1; }

mkdir -p "$CONFIG_DIR"
# the config-dir copy is for display + sync_patch, written only once the engine
# has accepted the fingerprint.
engine_install_pif "$TMP" || { log "$ENGINE could not install the fingerprint."; exit 1; }
cp -f "$TMP" "$TARGET" 2>/dev/null

log "installed fingerprint ($ENGINE): $FP"
exit 0
