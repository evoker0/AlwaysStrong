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

# Build-spoof (PIF-family) modules. They double-hook the bundled PlayIntegrityFork
# on the Fork/inject lines, so those lines disable them. The PIF-less "Lite" line
# ships NO Build spoof and is meant to run alongside the user's own PIF, so Lite
# KEEPS these — removing them there is exactly what stopped Lite + PlayIntegrityFork
# from working.
PIF_CONFLICTS='
playintegrityfix
playintegrityfork
play_integrity_fix
playcurl
playcurlNEXT
pif_strong
pif_force
'

# Keystore / TEE / target-list / global-prop modules. These fight the attestation
# engine (they hook keystore2 or rewrite the same target list / props) on EVERY
# line, Lite included, so they are always disabled.
CONFLICTS='
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
specter
'

MODPATH="${MODPATH:-/data/adb/modules/tricky_store}"

# The Lite line (ENGINE=none) bundles no PIF, so a standalone Build-spoof module
# is a wanted companion, not a conflict — only fold the PIF family into the removal
# list on the Fork/inject lines that DO bundle their own.
ENGINE=none
[ -f "$MODPATH/engine.sh" ] && . "$MODPATH/engine.sh" 2>/dev/null
[ "${ENGINE:-none}" != "none" ] && CONFLICTS="$CONFLICTS
$PIF_CONFLICTS"
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

# Shared-id special case: MeowDump's "Integrity Box" ships under the SAME module id
# as osm0sis PlayIntegrityFork (playintegrityfix, since IB v28). The Lite line keeps
# playintegrityfix for the plain Build-spoof Fork, but Integrity Box is a full
# keystore/attestation toolkit that fights the engine — so remove THAT one on every
# line, told apart by its module.prop (Fork's says osm0sis/PlayIntegrityFork and has
# no webuiIcon; IB carries MeowDump / Integrity-Box / a webuiIcon).
_ib=/data/adb/modules/playintegrityfix
if [ -d "$_ib" ] && [ "$SELF_BASENAME" != playintegrityfix ] \
   && grep -qiE 'MeowDump|Integrity-Box|integrity-box|webuiIcon' "$_ib/module.prop" 2>/dev/null; then
    touch "$_ib/disable" "$_ib/remove" 2>/dev/null
    [ -f "$_ib/uninstall.sh" ] && sh "$_ib/uninstall.sh" 2>/dev/null
    rm -rf /data/adb/modules_update/playintegrityfix 2>/dev/null
    removed=$((removed + 1))
    echo "disabled conflicting module: Integrity Box (playintegrityfix)" >> "$LOG" 2>/dev/null
fi

# Tell the caller how many we found, so service.sh can decide whether to log.
exit $removed
