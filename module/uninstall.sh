#!/system/bin/sh
# AlwaysStrong uninstall — clean every artifact we created.

MODDIR=${0%/*}
CONFIG_DIR=/data/adb/tricky_store

# Kill all running module processes
for proc in TEESimulator supervisor daemon; do
    for pid in $(pidof "$proc" 2>/dev/null); do
        kill -9 "$pid" 2>/dev/null
    done
done
pkill -9 -f TEESimulator 2>/dev/null || true
pkill -9 -f org.matrix.TEESimulator 2>/dev/null || true

# Kill GMS + Vending so they reload without our hooks
killall -9 com.google.android.gms.unstable 2>/dev/null
killall -9 com.google.android.gms 2>/dev/null
am force-stop com.android.vending 2>/dev/null

# Wipe TEESimulator runtime state
rm -rf "$CONFIG_DIR/persistent_keys"
rm -f "$CONFIG_DIR/tee_status.txt"
rm -f "$CONFIG_DIR/boot_hash.bin" "$CONFIG_DIR/boot_key.bin"

# Global PIF prop we dropped for the TEE PatchLevelManager (sync_patch.sh)
rm -f /data/adb/pif.prop

# Remove any stale playintegrityfix folder left by older shim-based builds
rm -rf /data/adb/modules/playintegrityfix 2>/dev/null

# Keep keybox.xml and security_patch.txt — user may want them for reinstall.
