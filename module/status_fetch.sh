#!/system/bin/sh
# Fetch the keybox status (e.g. "🟢🟢🟢") from the project's keybox mirror
# and prepend it to module.prop's description line so KSU/APatch/MMRL show
# the current health at a glance.
#
# Format: "description=🟢🟢🟢 <base>"   ← status first, then a space, then base
# Base text is the canonical line from description.txt (so we don't have
# to parse-and-strip arbitrary emoji prefixes — single source of truth).
#
# Called from action.sh (every press) and service.sh (hourly + first boot).
# Idempotent: only rewrites module.prop if the prefix actually changed.

URL="${STATUS_URL:-http://evoker.qzz.io/status}"
MODPATH="${MODPATH:-/data/adb/modules/tricky_store}"
PROP="$MODPATH/module.prop"
BASE_FILE="$MODPATH/description.txt"
CONFIG_DIR=/data/adb/tricky_store
NO_AUTO_FLAG="$CONFIG_DIR/no_auto_indicator"
TIMEOUT=10   # idle timeout per downloader; the outer cap per engine is CAP
CAP=45

# mode: "manual" (action button — always writes module.prop)
#       "auto"   (service.sh hourly — skips write if NO_AUTO_FLAG present)
#       "strip"  (WebUI indicator OFF — rewrite description to base, no fetch)
MODE="${1:-auto}"

[ -f "$PROP" ] || exit 1
[ -f "$BASE_FILE" ] || exit 1

# Strip mode: restore description= to the canonical base text from
# description.txt, removing any status prefix. Used by the WebUI when the
# user disables the indicator — they expect the emoji prefix to vanish from
# the module list immediately, not on the next reboot.
if [ "$MODE" = "strip" ]; then
    base=$(head -1 "$BASE_FILE" | tr -d '\r\n')
    [ -z "$base" ] && exit 4
    want="description=${base}"
    have=$(grep -m1 '^description=' "$PROP")
    [ "$have" = "$want" ] && exit 0
    tmp="${PROP}.tmp"
    awk -v new="$want" '
        !done && /^description=/ { print new; done=1; next }
        { print }
    ' "$PROP" > "$tmp" && mv -f "$tmp" "$PROP"
    exit 0
fi

# Auto path + user opted out of indicator → exit without touching module.prop.
# Hourly fp/keybox checks still happen in service.sh; only the visible 🟢
# prefix is gated. Manual action presses always update regardless.
if [ "$MODE" != "manual" ] && [ -f "$NO_AUTO_FLAG" ]; then
    exit 0
fi

BB=""
for p in /data/adb/modules/busybox-ndk/system/*/busybox /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    [ -f "$p" ] && BB="$p" && break
done

# Prefer the bundled native rustls fetcher: busybox wget's TLS stalls on the
# status/keybox CDN. asfetch with no -o writes the body straight to stdout.
SELF_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="${MODPATH:-/data/adb/modules/tricky_store}"
case "$(uname -m)" in
    aarch64)       SF_ABI=arm64-v8a ;;
    armv7*|armv8l) SF_ABI=armeabi-v7a ;;
    x86_64)        SF_ABI=x86_64 ;;
    i?86)          SF_ABI=x86 ;;
    *)             SF_ABI="" ;;
esac
ASFETCH="$SELF_DIR/bin/$SF_ABI/asfetch"

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

# No single downloader is reliable across devices (asfetch fails to connect on
# some, busybox wget stalls on the mirror CDN on others) — try each in turn and
# take the first non-empty body.
get_status() {
    if [ -n "$SF_ABI" ] && [ -x "$ASFETCH" ]; then
        _b=$(bounded "$CAP" "$ASFETCH" -T "$TIMEOUT" "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    if [ -n "$BB" ]; then
        _b=$(bounded "$CAP" "$BB" wget -q -T "$TIMEOUT" -O - "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    if command -v curl >/dev/null 2>&1; then
        _b=$(bounded "$CAP" curl -fsSL --connect-timeout 15 --speed-limit 1 --speed-time "$TIMEOUT" --max-time 40 "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    if command -v wget >/dev/null 2>&1; then
        _b=$(bounded "$CAP" wget -q -T "$TIMEOUT" -O - "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    return 1
}

new=$(get_status)
[ -z "$new" ] && exit 3
# A captive portal / hotel Wi-Fi answers every URL with an HTML login page. That
# is not a status — never stamp it into module.prop.
case "$new" in *'<'*|*'>'*|*'{'*) exit 3 ;; esac

base=$(head -1 "$BASE_FILE" | tr -d '\r\n')
[ -z "$base" ] && exit 4

want="description=${new} ${base}"
have=$(grep -m1 '^description=' "$PROP")

[ "$have" = "$want" ] && exit 0

# Atomic rewrite: produce full file in tmp, swap in.
tmp="${PROP}.tmp"
awk -v new="$want" '
    !done && /^description=/ { print new; done=1; next }
    { print }
' "$PROP" > "$tmp" && mv -f "$tmp" "$PROP"
