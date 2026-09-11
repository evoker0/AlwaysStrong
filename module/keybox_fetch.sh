#!/system/bin/sh
# AlwaysStrong — keybox auto-fetch.
#
# Downloads a base64-encoded keybox from the project's keybox mirror
# ($BASE_URL/key), hashes the downloaded bytes locally to detect whether
# anything changed since the last apply, decodes, validates that the payload
# looks like a keybox, then atomically replaces the target file. Override the
# source endpoint with the KEYBOX_BASE_URL env var.
#
# Exit codes:
#   0  keybox updated (new content written)
#   2  no change (already up to date)
#   1  fetch / verify failed (existing keybox preserved)

BASE_URL="${KEYBOX_BASE_URL:-http://evoker.qzz.io}"
KEY_URL="$BASE_URL/key"

CONFIG_DIR=/data/adb/tricky_store
TARGET="$CONFIG_DIR/keybox.xml"

log() { echo "keybox_fetch: $*"; }

# Custom-keybox mode: the user manages keybox.xml themselves via the WebUI —
# never fetch or overwrite it. (Defensive; action.sh/service.sh also gate on this.)
if [ -f "$CONFIG_DIR/custom_keybox" ]; then
    log "custom keybox active — skipping fetch."
    exit 2
fi

if [ -z "$BASE_URL" ]; then
    log "no KEYBOX_BASE_URL configured — skipping."
    exit 1
fi

# ---- Resolve tools ----
# No single downloader works on every device: busybox wget's built-in TLS
# stalls mid-stream on the keybox mirror CDN on some devices, while our bundled
# rustls fetcher (asfetch) fails to connect on others. So we try each available
# engine in turn (asfetch → busybox wget → curl → system wget) and keep the
# first that actually returns bytes — never trust one tool to always work.
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
for bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox \
          /data/adb/modules/busybox-ndk/system/*/busybox "$(command -v busybox 2>/dev/null)"; do
    [ -n "$bb" ] && [ -x "$bb" ] && BB="$bb" && break
done

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
# run_engine NAME OUTFILE URL — one download attempt with the named engine.
# Each engine's own -T bounds one idle wait; the outer cap bounds the call.
run_engine() {
    rm -f "$2"
    case "$1" in
        asfetch) [ -n "$ABI" ] && [ -f "$ASFETCH" ] && { [ -x "$ASFETCH" ] || chmod 0755 "$ASFETCH" 2>/dev/null; } && bounded 90 "$ASFETCH" -T 15 -o "$2" "$3" 2>/dev/null ;;
        bb)      [ -n "$BB" ] && bounded 90 "$BB" wget -q -T 20 -O "$2" "$3" 2>/dev/null ;;
        curl)    command -v curl >/dev/null 2>&1 && bounded 90 curl -fsSL --connect-timeout 15 --speed-limit 1 --speed-time 20 --max-time 85 -o "$2" "$3" 2>/dev/null ;;
        wget)    command -v wget >/dev/null 2>&1 && bounded 90 wget -q -T 20 -O "$2" "$3" 2>/dev/null ;;
    esac
    [ -s "$2" ]
}

# try_fetch OUTFILE URL — try each engine until one returns a non-empty file.
# The engine that last worked is remembered ($CONFIG_DIR/.kb_engine) and tried
# first, so we don't burn a fetcher's full timeout on every call.
CACHE="$CONFIG_DIR/.kb_engine"
try_fetch() {
    _o="$1"; _u="$2"
    _first=$(cat "$CACHE" 2>/dev/null)
    for _e in "$_first" asfetch bb curl wget; do
        [ -z "$_e" ] && continue
        if run_engine "$_e" "$_o" "$_u"; then
            [ "$_e" != "$_first" ] && echo "$_e" > "$CACHE" 2>/dev/null
            return 0
        fi
    done
    return 1
}

B64DEC=""
if echo dGVzdA== | base64 -d >/dev/null 2>&1; then
    B64DEC="base64 -d"
else
    for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$bb" ] && echo dGVzdA== | "$bb" base64 -d >/dev/null 2>&1; then
            B64DEC="$bb base64 -d"; break
        fi
    done
fi
[ -z "$B64DEC" ] && { log "no base64 decoder available."; exit 1; }

SHA256=""
if command -v sha256sum >/dev/null 2>&1; then
    SHA256="sha256sum"
else
    for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$bb" ] && echo x | "$bb" sha256sum >/dev/null 2>&1; then
            SHA256="$bb sha256sum"; break
        fi
    done
fi
[ -z "$SHA256" ] && { log "no sha256sum available."; exit 1; }

# ---- Fetch ----
mkdir -p "$CONFIG_DIR"
TMP="$CONFIG_DIR/.keybox_fetch.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

try_fetch "$TMP/key" "$KEY_URL" || { log "download failed on all engines ($KEY_URL)"; exit 1; }

if [ ! -s "$TMP/key" ]; then
    log "downloaded file is empty."
    exit 1
fi

# ---- Decode ----
# Always decode the downloaded payload, regardless of cache state. That
# way we can compare the upstream XML byte-for-byte against the file
# currently on disk — which catches the "user manually swapped the
# keybox under us" case that a STATE-file-based cache would miss.
$B64DEC < "$TMP/key" > "$TMP/keybox.xml" 2>/dev/null
if [ ! -s "$TMP/keybox.xml" ]; then
    log "base64 decode produced empty output — bad payload."
    exit 1
fi
if ! head -c 4096 "$TMP/keybox.xml" | grep -q "Keybox"; then
    log "decoded payload does not look like a keybox — discarding."
    exit 1
fi

NEW_XML_HASH=$($SHA256 < "$TMP/keybox.xml" | awk '{print tolower($1)}')
DISK_HASH=""
[ -s "$TARGET" ] && DISK_HASH=$($SHA256 < "$TARGET" | awk '{print tolower($1)}')

# ---- Change detection (compare actual on-disk XML, not a side-state) ---
if [ -n "$DISK_HASH" ] && [ "$DISK_HASH" = "$NEW_XML_HASH" ]; then
    log "already up to date."
    exit 2
fi

# ---- Atomic replace ----
mv -f "$TMP/keybox.xml" "$TARGET" || { log "mv to $TARGET failed."; exit 1; }
chmod 600 "$TARGET"
# Vestigial state file from older versions — clean up so it doesn't
# confuse anyone debugging.
rm -f "$CONFIG_DIR/.keybox.sha256" 2>/dev/null
log "$TARGET updated ($(wc -c < "$TARGET") bytes)."

# Tell the attestation engine the keybox changed. TEESimulator-RS and
# TrickyStoreOSS watch this directory themselves; JingMatrix TEESimulator only
# watches /data/adb/teesim, where our keybox is a symlink into here, and inotify
# never sees a write to a symlink's target — its adapter rewrites config.json so
# the daemon re-reads the keybox. No-op on the other engines. Subshell so the
# adapter's variables don't leak into this script.
_md=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -f "$_md/attest.sh" ] || _md=/data/adb/modules/tricky_store
if [ -f "$_md/attest.sh" ]; then
    ( MODPATH="$_md"; . "$_md/attest.sh" 2>/dev/null
      command -v attest_notify >/dev/null 2>&1 && attest_notify ) >/dev/null 2>&1
fi
exit 0
