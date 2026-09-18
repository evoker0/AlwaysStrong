#!/system/bin/sh
# logcat_cleanup.sh — logcat leak prevention
#
# Detection apps can scan logcat / ANR traces / tombstones for our tags or
# process names. This script:
#   1. Suppresses our log tags at the source via persist.log.tag.* props so
#      logd drops them before they ever reach a buffer (clean — no scrubbing).
#   2. Periodically sanitizes ANR/tombstone files by removing only our own
#      reference lines (per-line sed, never a full delete).
#
# Deliberately does NOT clear logcat buffers (`logcat -c`): a recently-cleared
# buffer is itself a detection signal, and wiping shared buffers would destroy
# other apps' logs. Source-level tag suppression (step 1) makes that
# unnecessary — our lines never enter the buffer in the first place.
#
# Opt out: logcat_cleanup=0 in alwaysstrong/config

MODDIR="${MODPATH:-$(dirname "$0")}"
LOG_DIR="$MODDIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null

LOG_TAG="AlwaysStrong"
LOG_FILE="$LOG_DIR/module.log"

log_private() {
  local ts=$(date '+%m-%d %H:%M:%S' 2>/dev/null)
  echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null
  tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null
}

# --- 1. Suppress our log tags at the source (logd drops them) ---
for t in AlwaysStrong AlwaysStrong-boot AlwaysStrong-hourly AlwaysStrong-unify \
         AlwaysStrong-proc AlwaysStrong-keybox; do
  resetprop "persist.log.tag.$t" S 2>/dev/null
done

# Remove any lingering temp log files from previous runs
rm -f /data/local/tmp/AlwaysStrong*.log 2>/dev/null

# --- 2. ANR / tombstone scrub (per-line sed, never full delete) ---
scrub_traces() {
  local changed=0
  local pat='TEESimulator\|aswatcher\|AlwaysStrong\|libinject\|libTEESimulator\|supervisor'

  for anr in /data/anr/anr_* /data/anr/traces.txt; do
    [ -f "$anr" ] || continue
    grep -q "TEESimulator\|aswatcher\|AlwaysStrong" "$anr" 2>/dev/null && {
      sed -i "/$pat/d" "$anr" 2>/dev/null
      log_private "sanitized ANR: $anr"
      changed=1
    }
  done

  for tomb in /data/tombstones/tombstone_*; do
    [ -f "$tomb" ] || continue
    grep -q "TEESimulator\|aswatcher\|AlwaysStrong" "$tomb" 2>/dev/null && {
      sed -i "/$pat/d" "$tomb" 2>/dev/null
      log_private "sanitized tombstone: $tomb"
      changed=1
    }
  done

  [ "$changed" = 1 ] && log_private "traces scrubbed"
}

# --- 3. Periodic scrub daemon ---
{
  while true; do
    scrub_traces 2>/dev/null
    sleep 1800  # every 30 min
  done
} &

log_private "logcat cleanup initialized"
