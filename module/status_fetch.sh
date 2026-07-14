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
TIMEOUT=8

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

# No single downloader is reliable across devices (asfetch fails to connect on
# some, busybox wget stalls on the mirror CDN on others) — try each in turn and
# take the first non-empty body.
get_status() {
    if [ -n "$SF_ABI" ] && [ -x "$ASFETCH" ]; then
        _b=$("$ASFETCH" -T "$TIMEOUT" "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    if [ -n "$BB" ]; then
        _b=$("$BB" wget -q -T "$TIMEOUT" -O - "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    if command -v curl >/dev/null 2>&1; then
        _b=$(curl -fsSL --max-time "$TIMEOUT" "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    if command -v wget >/dev/null 2>&1; then
        _b=$(wget -q -T "$TIMEOUT" -O - "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    return 1
}

new=$(get_status)
[ -z "$new" ] && exit 3

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
