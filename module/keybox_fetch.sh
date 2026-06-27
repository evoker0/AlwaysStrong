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

BASE_URL="${KEYBOX_BASE_URL:-https://botkey.netlify.app}"
KEY_URL="$BASE_URL/key"

CONFIG_DIR=/data/adb/tricky_store
TARGET="$CONFIG_DIR/keybox.xml"

log() { echo "keybox_fetch: $*"; }

if [ -z "$BASE_URL" ]; then
    log "no KEYBOX_BASE_URL configured — skipping."
    exit 1
fi

# ---- Resolve tools ----
DL=""
if command -v curl >/dev/null 2>&1; then
    DL="curl -fsSL --connect-timeout 10 --max-time 30 -o"
elif command -v wget >/dev/null 2>&1; then
    DL="wget -q -O"
else
    for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$bb" ]; then DL="$bb wget -q -O"; break; fi
    done
fi
[ -z "$DL" ] && { log "no curl/wget/busybox — cannot fetch."; exit 1; }

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

$DL "$TMP/key" "$KEY_URL" || { log "download failed ($KEY_URL)"; exit 1; }

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
exit 0
