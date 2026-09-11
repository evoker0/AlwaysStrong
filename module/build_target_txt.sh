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

# The base app pool (user installs + installed OEM wallet/store apps + the forced
# Google trio) as PLAIN package names. The `!` suffix — TrickyStore's generate /
# "cert-generating" mode — is applied per app below, from the forced defaults and
# the WebUI overrides, so it lives in exactly one place.
build_default() {
    pm list packages -3 2>/dev/null \
        | sed 's/^package://' \
        | grep -Fxv -e com.android.vending \
                    -e com.google.android.gms \
                    -e com.google.android.gsf
    for p in $OEM_LIST;    do is_installed "$p" && echo "$p"; done
    for p in $FORCED_LIST; do is_installed "$p" && echo "$p"; done
}

DEF=$(build_default | sort -u)

# Per-app overrides managed by the WebUI — the single source of truth, re-read on
# every rebuild so a choice survives regeneration (aswatcher only re-runs THIS
# script, it never appends packages itself). Each line: "pkg<TAB>spec":
#   spec = "off"          -> unticked: dropped from target.txt, never re-added.
#   spec = "<kb>|<mode>"     kb   = "-" (default keybox.xml) or a filename in the
#                                   config dir -> app goes into that "[file.xml]"
#                                   section so TrickyStore reads that keybox.
#                            mode = "auto" (no suffix, let TrickyStore decide),
#                                   "gen" (generate the whole chain -> "!"), or
#                                   "hack" (hack leaf cert -> "?").
#   (no line)             -> ticked, default keybox, auto; forced trio -> gen.
MAP="$(dirname "$TGT")/app_keybox.map"
[ -f "$MAP" ] || MAP=""
FORCED="com.android.vending com.google.android.gms com.google.android.gsf"

{
    # --- default-keybox section (kb == "-"): plain list + per-app ! suffix ---
    printf '%s\n' "$DEF" | sed '/^$/d' | awk -v mapf="$MAP" -v forced="$FORCED" '
        function sfx(p, spec,   n,b,mode){
            mode="";
            if(spec!="" && spec!="off"){ n=split(spec,b,"|"); if(n>=2) mode=b[2] }
            if(mode=="") mode=(p in F)?"gen":"auto";
            return (mode=="gen")?"!":(mode=="hack")?"?":"";
        }
        function kbof(spec,   n,b){
            if(spec==""||spec=="off") return "-";
            n=split(spec,b,"|"); return (b[1]==""?"-":b[1]);
        }
        BEGIN{
            split(forced,a," "); for(i in a) F[a[i]]=1;
            if(mapf!=""){ while((getline ln<mapf)>0){ t=index(ln,"\t"); if(t==0) continue;
                M[substr(ln,1,t-1)]=substr(ln,t+1) } }
        }
        { p=$0; spec=(p in M)?M[p]:"";
          if(spec=="off") next;             # unticked
          if(kbof(spec)!="-") next;         # assigned to a keybox file -> a section
          print p sfx(p,spec); }
    '
    # --- one "[file.xml]" section per assigned keybox (sorted -> stable output) ---
    if [ -n "$MAP" ]; then
        awk -F'\t' -v forced="$FORCED" '
            BEGIN{ split(forced,a," "); for(i in a) F[a[i]]=1 }
            $1!="" {
                spec=$2; if(spec=="off") next;
                n=split(spec,b,"|"); kb=(b[1]==""?"-":b[1]); if(kb=="-") next;
                mode=(n>=2?b[2]:""); if(mode=="") mode=($1 in F)?"gen":"auto";
                print kb "\t" $1 ((mode=="gen")?"!":(mode=="hack")?"?":"");
            }' "$MAP" | sort | awk -F'\t' '
            $1!=prev{ printf "\n[%s]\n", $1; prev=$1 } { print $2 }'
    fi
} > "${TGT}.tmp" && mv -f "${TGT}.tmp" "$TGT"

# --- GC orphaned WebUI-imported keyboxes ---------------------------------
# The WebUI records every keybox it imports into the config dir in
# .imported_keyboxes (one filename per line). A file listed there that no map
# entry references anymore is a dead import — delete it so the config dir does
# not accumulate stale keyboxes. ONLY files we imported are ever touched:
# manually-dropped keyboxes are never in the manifest, so they are left alone.
# keybox.xml (the default) is never a managed import and is skipped defensively.
# If the map is gone entirely, every import is orphaned -> all get cleaned.
CFG_DIR="$(dirname "$TGT")"
MANIFEST="$CFG_DIR/.imported_keyboxes"
if [ -f "$MANIFEST" ]; then
    # Keyboxes still referenced by a non-off map entry (kb field != "-").
    REFERENCED=""
    if [ -n "$MAP" ]; then
        REFERENCED=$(awk -F'\t' '
            $1!="" { spec=$2; if(spec=="off") next;
                     n=split(spec,b,"|"); kb=(b[1]==""?"-":b[1]);
                     if(kb!="-") print kb }' "$MAP" | sort -u)
    fi
    NEWMAN=""
    while IFS= read -r fn; do
        [ -n "$fn" ] || continue
        [ "$fn" = "keybox.xml" ] && continue
        if printf '%s\n' "$REFERENCED" | grep -Fxq "$fn"; then
            NEWMAN="${NEWMAN}${fn}
"                                       # still used -> keep file + manifest line
        else
            rm -f "$CFG_DIR/$fn" 2>/dev/null    # orphan -> delete the keybox file
        fi
    done < "$MANIFEST"
    printf '%s' "$NEWMAN" > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
fi

# Tell the attestation engine target.txt changed. TEESimulator-RS and
# TrickyStoreOSS watch the file themselves; JingMatrix TEESimulator has its own
# /data/adb/teesim/config.json, and its adapter regenerates the app list from
# target.txt there. Runs for every caller (Action, aswatcher, WebUI), so a target
# change reaches that engine now instead of on the hourly tick. Subshell so the
# adapter's variables don't leak.
_md=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -f "$_md/attest.sh" ] || _md=/data/adb/modules/tricky_store
if [ -f "$_md/attest.sh" ]; then
    ( MODPATH="$_md"; . "$_md/attest.sh" 2>/dev/null
      command -v attest_notify >/dev/null 2>&1 && attest_notify ) >/dev/null 2>&1
fi
