#!/system/bin/sh
# Block ROM-level Play Integrity spoof engines.
#
# Adapted from dpejoh/specter (block_rom_spoof_engines in src/lib/common.sh).
# Custom ROMs (LineageOS, EvolutionX, PixelOS, …) ship their own pixel-prop /
# pihook / entryhook spoofers that fight ours: they re-set Build.* every boot,
# corrupt the attestation chain, and on STRONG checks the leaked extra hooks
# get flagged. We disable the ROM engines so AlwaysStrong is the single
# source of truth for the spoofed fingerprint.
#
# Opt-out:  touch /data/adb/tricky_store/no_rom_spoof_block
# Called from post-fs-data.sh (early, before GMS starts).

CONFIG_DIR=/data/adb/tricky_store
[ -f "$CONFIG_DIR/no_rom_spoof_block" ] && exit 0

GMS_PROPS_FILE="/data/system/gms_certified_props.json"

# Detection — only act if a ROM spoof engine (or a spoofing custom ROM) is
# present. The prop/version list mirrors PlayIntegrityFork's common_setup.sh
# (osm0sis), which tracks the current AOSPA / PixelOS / Afterlife / EvolutionX /
# crDroid PropImitationHooks / PixelPropsUtils engines.
gate=0
resetprop 2>/dev/null | grep -qE 'persist\.sys\.(pihooks|entryhooks|spoof|pixelprops|pp)' && gate=1
[ -n "$(resetprop ro.aospa.version 2>/dev/null)" ] && gate=1
[ -n "$(resetprop net.pixelos.version 2>/dev/null)" ] && gate=1
[ -n "$(resetprop ro.afterlife.version 2>/dev/null)" ] && gate=1
[ -f "$GMS_PROPS_FILE" ] && gate=1
[ "$gate" = "0" ] && exit 0

set_persist() {
    resetprop -n -p "$1" "$2" 2>/dev/null
}

# Seed empty values for hooks that PihookGMS/EntryHooks read at startup, so
# the engine sees the slot already occupied and bails instead of writing its
# own. Skip if already set (don't clobber whatever the ROM has).
for hook in persist.sys.pihooks.first_api_level persist.sys.pihooks.security_patch; do
    resetprop 2>/dev/null | grep -q "$hook" || set_persist "$hook" ""
done

# Hard-disable the known ROM spoof toggles. The list + values mirror
# PlayIntegrityFork's common_setup.sh (osm0sis) exactly, so we cover the same
# engines PIF does. Any future hook we don't know about gets the persist-prop
# wipe below as a catch-all.
set_persist persist.sys.pihooks.disable.gms_props                 true
set_persist persist.sys.pihooks.disable.gms_key_attestation_block true
set_persist persist.sys.entryhooks_enabled                        false
set_persist persist.sys.spoof.gms                                 false
set_persist persist.sys.pixelprops.gms                            false
set_persist persist.sys.pixelprops.gapps                          false
set_persist persist.sys.pixelprops.google                         false
set_persist persist.sys.pixelprops.pi                             false
set_persist persist.sys.pp.gms                                    false
set_persist persist.sys.pp.finsky                                 false

# Wipe any leftover pihook/pixelprops props that we didn't explicitly handle
# — keeps the prop table clean of identifiable spoof-engine markers that PI
# could fingerprint on.
getprop 2>/dev/null | grep -E '(pihook|pixelprops)' | sed 's/^\[\(.*\)\]:.*/\1/' | \
while IFS= read -r prop; do
    [ -z "$prop" ] && continue
    resetprop -p --delete "$prop" 2>/dev/null || true
done

exit 0
