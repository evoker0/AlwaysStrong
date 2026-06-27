#!/system/bin/sh
# Build /data/adb/tricky_store/target.txt from:
#   1. user-installed packages (`pm list packages -3`) -- auto mode
#   2. a small curated OEM-app list (Samsung Pay etc.) -- auto, included only
#      if actually installed on this device
#   3. Play Store / Play Services / Play Services Framework -- forced live (`!`)
#      because GMS/GSF/Vending must use the hardware keybox to ever reach
#      STRONG; auto mode here will silently downgrade to software when TEE
#      fails and that's the most common "why is my keybox not working" cause.
#
# Usage:
#   sh build_target_txt.sh /data/adb/tricky_store/target.txt
#
# Anything not in this seed gets auto-added by the ta-enhanced inotify daemon
# at runtime (PackageManager watcher), so this script's job is the initial
# seed and the periodic action-button rebuild only.

TGT="${1:-/data/adb/tricky_store/target.txt}"

# Bail out early if pm is unreachable -- keep existing target.txt as-is.
pm list packages >/dev/null 2>&1 || exit 1

ALL=$(pm list packages 2>/dev/null | sed 's/^package://')

# OEM payment / wallet / store apps that ship pre-installed (so `-3` misses
# them) but legitimately call the Play Integrity API. Add only if actually
# present on this device.
OEM_LIST="
com.samsung.android.spay
com.samsung.android.samsungpay.gear
com.samsung.android.spaytui
com.samsung.android.app.spage
com.sec.android.app.samsungapps
com.huawei.wallet
com.huawei.android.hwpay
com.miui.securitycenter
com.xiaomi.market
com.oneplus.opbackup
com.oplus.wallet
com.google.android.apps.walletnfcrel
com.google.android.apps.nbu.paisa.user
"

# Forced live -- always !, never downgrade.
FORCED_LIST="
com.android.vending
com.google.android.gms
com.google.android.gsf
"

is_installed() { printf '%s\n' "$ALL" | grep -Fxq "$1"; }

{
    # User installs (`-3`). This skips system apps including system-updated
    # GMS/GSF/Vending, which is why the FORCED_LIST below explicitly re-adds
    # them with the ! flag. Filter the 3 forced names defensively in case a
    # weird ROM ever surfaces them through `-3` -- we don't want both a
    # `foo` and a `foo!` line for the same package.
    pm list packages -3 2>/dev/null \
        | sed 's/^package://' \
        | grep -Fxv -e com.android.vending \
                    -e com.google.android.gms \
                    -e com.google.android.gsf

    for p in $OEM_LIST; do
        is_installed "$p" && echo "$p"
    done

    for p in $FORCED_LIST; do
        is_installed "$p" && echo "${p}!"
    done
} | sort -u > "${TGT}.tmp" && mv -f "${TGT}.tmp" "$TGT"
