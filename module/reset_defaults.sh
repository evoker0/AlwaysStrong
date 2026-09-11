#!/system/bin/sh
# AlwaysStrong — reset the WebUI-tunable settings to a fresh-install state.
#
# Called from the WebUI (Advanced → Reset to defaults) and usable from a root
# shell:  sh /data/adb/modules/tricky_store/reset_defaults.sh
#
# Every setting the WebUI can change defaults to "file absent", so a reset is
# purely deletions; then the Action re-runs in the background, which is the
# same path a fresh install takes (target list, fingerprint fetch with all its
# fallbacks, STRONG spoof flags, security patch, Play Integrity restart). The
# fetched fingerprint overwrites an imported one, so nothing needs deleting for
# that either — and deleting it would leave no fingerprint if the network is
# down.
#
# Deliberately kept:
#   keybox.xml, custom_keybox + the imported per-app keyboxes and their map
#     (user data, and the auto-fetch would overwrite a user's own keybox)
#   hbk, security_patch.txt, pif files, target.txt (derived state; Action
#     regenerates what needs regenerating)
#   the WebUI language (a browser preference, not a module setting)

case "$0" in
    */*) MODPATH=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
    *)   MODPATH="$PWD" ;;
esac
[ -f "$MODPATH/module.prop" ] || MODPATH=/data/adb/modules/tricky_store
CFG=/data/adb/tricky_store

# Opt-out flags (file present = feature off), the legacy force-on patch flag,
# the interval, the Advanced spoof-flag overrides and the custom target packages.
for f in no_auto_fp no_auto_keybox no_auto_indicator no_rom_spoof_block \
         no_spoof_patch_props spoof_patch_props no_prop_unify hide_rom_markers \
         hourly_interval_sec spoof.conf custom_packages; do
    rm -f "$CFG/$f" 2>/dev/null
done

# The status prefix is default-on again; the next status fetch writes it back.
# Re-run the Action in the background, exactly like the first boot does: under
# busybox ash when available (action.sh's `set +o standalone` needs it), with
# AS_FAST=1 so the cosmetic progress sleeps are skipped.
BB=""
for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
          /data/adb/modules/busybox-ndk/system/*/busybox; do
    [ -x "$bb" ] && BB="$bb" && break
done
if [ -x "$MODPATH/action.sh" ] || [ -f "$MODPATH/action.sh" ]; then
    if [ -n "$BB" ]; then
        AS_FAST=1 "$BB" sh "$MODPATH/action.sh" >"$CFG/.action_reset.log" 2>&1 &
    else
        AS_FAST=1 sh "$MODPATH/action.sh" >"$CFG/.action_reset.log" 2>&1 &
    fi
fi

echo "OK"
exit 0
