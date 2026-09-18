#!/system/bin/sh
# prop_unify.sh — unify ro.product.* props with the spoofed fingerprint
#
# PlayIntegrityFork spoofs Build.* inside the GMS process, but the
# ro.product.* family (ro.product.manufacturer/model/name/device/brand) stays
# at the real device values in the global property store. Detection apps that
# read those props via getprop — rather than the Build class — can spot the
# mismatch against the spoofed fingerprint. This closes that cross-validation
# gap by resetprop-ing the product family to match the active pif fingerprint.
#
# Opt out: prop_unify=0 in alwaysstrong/config

MODDIR="${MODPATH:-$(dirname "$0")}"
CFG=/data/adb/tricky_store

# Callers pipe our stdout to `log -t AlwaysStrong-unify`, so just echo — a
# log() wrapper that calls `log` would recurse into itself (functions shadow
# same-named commands), not the Android log binary.
log() { echo "$@"; }

# Source of truth: the active pif file — custom.pif.prop first (what PIF reads),
# then pif.prop. Same order as sync_patch.sh / status_json.sh so they agree.
PIF=""
for p in "$CFG/custom.pif.prop" "$CFG/pif.prop"; do
  [ -s "$p" ] && PIF="$p" && break
done

if [ -z "$PIF" ]; then
  log "no pif.prop found under $CFG — skipping prop unification"
  exit 0
fi

# Resetprop helpers — use '-n' to avoid triggering property triggers
set_prop() {
  local key="$1" val="$2"
  local cur
  cur=$(resetprop "$key" 2>/dev/null)
  [ "$cur" = "$val" ] && return 0
  resetprop -n "$key" "$val" 2>/dev/null
  log "  $key <- $val"
}

del_prop() {
  resetprop --delete "$1" 2>/dev/null
}

log "unifying product props from $PIF"

# Parse pif for FINGERPRINT and the explicit override fields
FINGERPRINT=""
PRODUCT=""
DEVICE=""
MANUFACTURER=""
BRAND=""
MODEL=""
SECURITY_PATCH=""

while IFS='=' read -r key val; do
  case "$key" in
    FINGERPRINT)     FINGERPRINT="$val" ;;
    PRODUCT)         PRODUCT="$val" ;;
    DEVICE)          DEVICE="$val" ;;
    MANUFACTURER)    MANUFACTURER="$val" ;;
    BRAND)           BRAND="$val" ;;
    MODEL)           MODEL="$val" ;;
    SECURITY_PATCH)  SECURITY_PATCH="$val" ;;
  esac
done < "$PIF"

# Derive brand/product/device from the fingerprint when not overridden.
# Format: brand/product/device:build_type/release/id/incremental:tags/keys
if [ -n "$FINGERPRINT" ]; then
  FP_BRAND="${FINGERPRINT%%/*}"
  AFTER_BRAND="${FINGERPRINT#*/}"
  FP_PRODUCT="${AFTER_BRAND%%/*}"
  AFTER_PRODUCT="${AFTER_BRAND#*/}"
  FP_DEVICE_TMP="${AFTER_PRODUCT%%:*}"
  FP_DEVICE="${FP_DEVICE_TMP%%/*}"

  FP_BUILD_TYPE="user"
  case "$FINGERPRINT" in
    *:userdebug/*) FP_BUILD_TYPE="userdebug" ;;
    *:eng/*)       FP_BUILD_TYPE="eng" ;;
  esac

  [ -n "$DEVICE" ]  && FP_DEVICE="$DEVICE"
  [ -n "$PRODUCT" ] && FP_PRODUCT="$PRODUCT"
  [ -n "$BRAND" ]   && FP_BRAND="$BRAND"

  log "fingerprint -> brand=$FP_BRAND product=$FP_PRODUCT device=$FP_DEVICE"

  # Manufacturer first, so it isn't clobbered by the lowercase brand.
  if [ -n "$MANUFACTURER" ]; then
    set_prop ro.product.manufacturer "$MANUFACTURER"
  elif [ -n "$FP_BRAND" ]; then
    set_prop ro.product.manufacturer "$FP_BRAND"
  fi

  [ -n "$FP_BRAND" ] && set_prop ro.product.brand "$FP_BRAND"

  [ -n "$FP_PRODUCT" ] && {
    set_prop ro.product.name "$FP_PRODUCT"
    set_prop ro.product.device "$FP_PRODUCT"
    set_prop ro.build.product "$FP_PRODUCT"
  }

  [ -n "$FP_DEVICE" ] && [ "$FP_DEVICE" != "$FP_PRODUCT" ] && {
    set_prop ro.product.device "$FP_DEVICE"
  }

  if [ -n "$MODEL" ]; then
    set_prop ro.product.model "$MODEL"
    set_prop ro.product.system.model "$MODEL"
  fi

  # ro.build.description — reconstruct from fingerprint fields. Real format:
  #   brand/product/device:release/id/incremental:type/tags
  # (there is NO build_type before release — that was the old off-by-one bug).
  REST="${FINGERPRINT#*:}"          # release/id/incremental:type/tags
  FP_RELEASE="${REST%%/*}"          # release (e.g. 15 or CANARY)
  REST2="${REST#*/}"                # id/incremental:type/tags
  FP_ID="${REST2%%/*}"              # build id (e.g. ZP11.260618.005)
  REST3="${REST2#*/}"               # incremental:type/tags
  FP_INCREMENTAL="${REST3%%:*}"     # incremental (e.g. 15760424)
  TYPETAGS="${REST3#*:}"            # type/tags (e.g. user/release-keys)
  FP_TAGS="${TYPETAGS#*/}"          # tags (release-keys)
  [ "$FP_TAGS" = "$TYPETAGS" ] && FP_TAGS="release-keys"

  # type comes from the already-correct FP_BUILD_TYPE derived above.
  BUILD_DESC="${FP_PRODUCT}-${FP_BUILD_TYPE} ${FP_RELEASE} ${FP_ID} ${FP_INCREMENTAL} ${FP_TAGS}"
  set_prop ro.build.description "$BUILD_DESC"

  [ -n "$SECURITY_PATCH" ] && {
    set_prop ro.build.version.security_patch "$SECURITY_PATCH"
    set_prop ro.vendor.build.security_patch "$SECURITY_PATCH"
    set_prop ro.build.version.real_security_patch "$SECURITY_PATCH"
  }

  # Scrub OEM-specific product props that would leak the real device.
  for part in odm vendor product system_ext; do
    for field in model brand manufacturer device name; do
      del_prop "ro.product.$part.$field"
    done
  done

  set_prop ro.build.tags "${FP_TAGS:-release-keys}"
  set_prop ro.build.type "${FP_BUILD_TYPE:-user}"
  set_prop ro.system.build.tags "${FP_TAGS:-release-keys}"
  set_prop ro.system.build.type "${FP_BUILD_TYPE:-user}"
fi

log "prop unification complete"
