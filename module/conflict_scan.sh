#!/system/bin/sh
# Scan installed modules for known conflicts with AlwaysStrong and disable
# them. Called at install time (customize.sh) AND on every boot (service.sh),
# because users do install conflicting modules after AlwaysStrong is already
# in place, and the symptoms (TEE getting hooked twice, target.txt fights,
# zygisk double-hooks) look like AlwaysStrong is broken.
#
# Disabling rather than deleting on every boot: the user's root manager
# may already have processed the module list; a `disable` marker is honored
# by Magisk/KSU/APatch at next boot, while `remove` schedules deletion.
# We do both, plus rm -rf for already-applied state. customize.sh handles
# install-time bulk removal; this script handles steady-state monitoring.

CONFLICTS='
playintegrityfix
playintegrityfork
play_integrity_fix
playcurl
playcurlNEXT
tricky_store_v2
TrickyStore
tee_simulator
TEESimulator
TEESimulator-RS
safetynet-fix
Universal_SafetyNet_Fix
MagiskHidePropsConf
TA_utl
tricky_addon
TA_enhanced
tsupport-advance
Yurikey
pif_strong
pif_force
specter
'

MODPATH="${MODPATH:-/data/adb/modules/tricky_store}"
LOG=${1:-/dev/null}
SELF_BASENAME=$(basename "$MODPATH")
removed=0

for c in $CONFLICTS; do
    [ "$c" = "$SELF_BASENAME" ] && continue
    d="/data/adb/modules/$c"
    [ -d "$d" ] || continue

    # Belt-and-braces: mark for both disable and removal so the next boot
    # picks whichever the root manager honors first.
    touch "$d/disable" "$d/remove" 2>/dev/null
    # Run upstream uninstall.sh if present — some modules use it to revert
    # persist-prop changes that would otherwise survive removal.
    [ -f "$d/uninstall.sh" ] && sh "$d/uninstall.sh" 2>/dev/null
    # Stale modules_update copies become next-boot installs if we leave them.
    [ -d "/data/adb/modules_update/$c" ] && rm -rf "/data/adb/modules_update/$c" 2>/dev/null
    removed=$((removed + 1))
    echo "disabled conflicting module: $c" >> "$LOG" 2>/dev/null
done

# Tell the caller how many we found, so service.sh can decide whether to log.
exit $removed
