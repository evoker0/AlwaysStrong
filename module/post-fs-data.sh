MODPATH="${0%/*}"
. $MODPATH/common_func.sh

# Our PIF zygisk binary is binary-patched at build time to read its dex/config
# from /data/adb/modules/tricky_store (our module dir) instead of the upstream
# hardcoded /data/adb/modules/playintegrityfix. So there is NO separate
# playintegrityfix folder to create here — everything lives under our module.
[ -f "$MODPATH/common_setup.sh" ] && . $MODPATH/common_setup.sh

# --- DenyList: hide root from the Play stack (Magisk) ---------------------
# Requested behaviour: GMS, GSF and Play Store always go on the DenyList so
# Magisk hides root from them. Our PIF zygisk module still injects into these
# processes regardless of DenyList membership, so Build/prop spoofing keeps
# working while root stays hidden — the two are independent in Zygisk mode.
if command -v magisk >/dev/null 2>&1; then
    magisk --denylist enable 2>/dev/null
    magisk --denylist add com.google.android.gms 2>/dev/null
    magisk --denylist add com.google.android.gms com.google.android.gms.unstable 2>/dev/null
    magisk --denylist add com.google.android.gsf 2>/dev/null
    magisk --denylist add com.android.vending 2>/dev/null
fi

# --- Security patch level (attestation + Build consistency) ---------------
# Writes /data/adb/tricky_store/security_patch.txt for the TEE attestation and
# pins ro.build.version.security_patch to match the spoofed fingerprint.
[ -f "$MODPATH/sync_patch.sh" ] && sh "$MODPATH/sync_patch.sh" boot 2>/dev/null

# --- Bootloader / verified boot props (required for STRONG, harmless if already correct) ---

# Samsung
resetprop_if_diff ro.boot.warranty_bit 0
resetprop_if_diff ro.vendor.boot.warranty_bit 0
resetprop_if_diff ro.vendor.warranty_bit 0
resetprop_if_diff ro.warranty_bit 0
resetprop_if_diff ro.boot.fmp_config 1
resetprop_if_diff ro.boot.dp_fw_check 1

# Realme
resetprop_if_diff ro.boot.realmebootstate green

# OnePlus
resetprop_if_diff ro.is_ever_orange 0

# Encryption state
resetprop_if_diff ro.crypto.state encrypted

# VBMeta integrity chain (helps some devices reach DEVICE verdict)
resetprop_if_diff ro.boot.vbmeta.hash_alg sha256
resetprop_if_diff ro.boot.vbmeta.avb_version 1.0
resetprop_if_diff ro.boot.vbmeta.invalidate_on_error yes
for p in /dev/block/by-name/vbmeta /dev/block/by-name/vbmeta_a /dev/block/bootdevice/by-name/vbmeta; do
    [ -e "$p" ] && VBMETA_BLK="$p" && break
done
if [ -n "$VBMETA_BLK" ]; then
    VBMETA_SIZE=$(blockdev --getsize64 "$VBMETA_BLK" 2>/dev/null)
    [ -n "$VBMETA_SIZE" ] && resetprop_if_diff ro.boot.vbmeta.size "$VBMETA_SIZE"
fi

# Build tags / type — all variants (system, vendor, product, system_ext, etc.)
for PROP in $(resetprop | grep -oE 'ro.*.build.tags'); do
    resetprop_if_diff $PROP release-keys
done
for PROP in $(resetprop | grep -oE 'ro.*.build.type'); do
    resetprop_if_diff $PROP user
done

resetprop_if_diff ro.adb.secure 1
if ! $SKIPDELPROP; then
    delprop_if_exist ro.boot.verifiedbooterror
    delprop_if_exist ro.boot.verifyerrorpart
fi
resetprop_if_diff ro.boot.veritymode.managed yes
resetprop_if_diff ro.debuggable 0
resetprop_if_diff ro.force.debuggable 0
resetprop_if_diff ro.secure 1

# Strip custom-ROM build leaks (LineageOS, etc.) — they're a tell to PI
for PROP in ro.lineage.build.version ro.lineage.version ro.lineage.display.version \
            ro.modversion ro.cm.version; do
    delprop_if_exist "$PROP" 2>/dev/null || true
done

# Disable ROM-level spoof engines (PixelPropsUtils / pihooks / entryhooks)
# before GMS starts. Gated by /data/adb/tricky_store/no_rom_spoof_block flag.
if [ -x "$MODPATH/rom_spoof_block.sh" ]; then
    sh "$MODPATH/rom_spoof_block.sh" 2>/dev/null || true
fi
