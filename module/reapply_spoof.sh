#!/system/bin/sh
# Re-apply the engine's STRONG spoof flags to every pif file it reads, then
# restart the Play Integrity consumers so the change takes effect immediately.
# Called from the WebUI right after the spoofProps toggle is flipped so the user
# doesn't have to press Action or wait for the hourly refresh.

case "$0" in
    */*) MODPATH=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
    *)   MODPATH="$PWD" ;;
esac
[ -z "$MODPATH" ] && MODPATH="$PWD"
CONFIG_DIR=/data/adb/tricky_store

BB=""
for bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox \
          /data/adb/modules/busybox-ndk/system/*/busybox "$(command -v busybox 2>/dev/null)"; do
    [ -n "$bb" ] && [ -x "$bb" ] && BB="$bb" && break
done
SED_I="sed -i"
[ -n "$BB" ] && SED_I="$BB sed -i"
export MODPATH CONFIG_DIR SED_I

[ -f "$MODPATH/engine.sh" ] || { echo "ERR: engine.sh missing"; exit 1; }
. "$MODPATH/engine.sh"

engine_enforce_spoof
killall -9 com.google.android.gms.unstable 2>/dev/null
killall -9 com.android.vending 2>/dev/null
echo "OK"
