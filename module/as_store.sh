#!/system/bin/sh
# AlwaysStrong's own storage — one directory instead of two dozen loose files.
#
# Everything the module keeps between boots used to be its own file in
# /data/adb/tricky_store: a marker file per toggle (no_auto_fp, no_auto_keybox,
# hide_rom_markers, ...), the interval, the per-app map, the logs, the engine
# loop pids and every download-in-flight, all mixed in with the keystore
# engine's own keybox.xml / target.txt / hbk / persistent_keys. The engine's
# files stay where the engine reads them; ours now live under one roof:
#
#   /data/adb/tricky_store/alwaysstrong/
#     config      user settings, key=value      (auto_fp=0, interval_sec=1800)
#     state       internal state, key=value     (kb_engine=asfetch, fp_idx=2)
#     apps.map    per-app keybox + mode          (was app_keybox.map)
#     packages    user-added target packages     (was custom_packages)
#     spoof.conf  spoof-flag overrides from the Advanced tab
#     imported    keyboxes imported from the WebUI, one file name per line
#     logs/       autopif.log, action-boot.log, action-reset.log
#     tmp/        downloads in flight, engine loop pids
#
# Anything new belongs in one of these as a LINE, not as another file: the
# directory next door is the engine's and this one should stay readable.
#
# Use it either way:
#   . "$MODPATH/as_store.sh"        # helpers: as_on, as_get, as_set, st_get, ...
#   sh as_store.sh get auto_fp      # or as a command, which is what the WebUI calls
#
# Settings are named for what they DO (auto_fp=1 means the fingerprint refreshes
# itself), never for what they switch off — the old "no_auto_fp exists" spelling
# made every read a double negative. Legacy layouts are imported on the first
# run by as_migrate, so an update keeps every setting the user had.

AS_CFG_ROOT=${AS_CFG_ROOT:-/data/adb/tricky_store}
AS_DIR="$AS_CFG_ROOT/alwaysstrong"
AS_CONF="$AS_DIR/config"
AS_STATE="$AS_DIR/state"
AS_APPS="$AS_DIR/apps.map"
AS_PKGS="$AS_DIR/packages"
AS_SPOOF="$AS_DIR/spoof.conf"
AS_IMPORTED="$AS_DIR/imported"
AS_LOGS="$AS_DIR/logs"
AS_TMP="$AS_DIR/tmp"

# Every helper below swallows the status of commands whose failure is normal
# (a key that is not there, a grep that matches nothing). A caller running under
# `set -e` — the installer, a test harness — would otherwise die on a setting
# simply being unset.
as_init() {
    mkdir -p "$AS_LOGS" "$AS_TMP" 2>/dev/null || :
    # module scripts run with umask 000, so say what these should be instead of
    # leaving the tree world-writable
    chmod 700 "$AS_DIR" "$AS_LOGS" "$AS_TMP" 2>/dev/null || :
    return 0
}

# Every setting there is, in the order the config file lists them.
AS_KEYS="auto_fp auto_keybox status_indicator rom_spoof_block spoof_patch_props
         force_patch_props logcat_cleanup prop_unify hide_rom_markers custom_keybox
         interval_sec"

# What a setting means when nothing has been written. Everything the module does
# on its own is on; the two opt-ins are off.
as_default() {
    case "$1" in
        auto_fp|auto_keybox|status_indicator|rom_spoof_block|spoof_patch_props|logcat_cleanup|prop_unify) echo 1 ;;
        custom_keybox|force_patch_props|hide_rom_markers) echo 0 ;;
        interval_sec) echo 3600 ;;
        *) echo "" ;;
    esac
}

# --- key=value files ------------------------------------------------------
# Values are single-line and never quoted; a key that is not in the file is
# simply unset, so a setting at its default costs no bytes at all.
_kv_get() {
    # _kv_get <file> <key> — empty when unset, and always a success status: a
    # caller running under `set -e` must not die just because a setting has
    # never been written.
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
    return 0
}

_kv_set() {
    # _kv_set <file> <key> <value> — rewritten through a temp file, so a kill
    # mid-write can never leave a half-line the next boot reads as garbage.
    as_init
    _kvf="$1"; _kvk="$2"; _kvv="$3"
    [ -f "$_kvf" ] || : > "$_kvf"
    { grep -v "^$_kvk=" "$_kvf" 2>/dev/null; echo "$_kvk=$_kvv"; } > "$_kvf.new" 2>/dev/null &&
        mv -f "$_kvf.new" "$_kvf" 2>/dev/null
    chmod 600 "$_kvf" 2>/dev/null || :
    unset _kvf _kvk _kvv
    return 0
}

_kv_del() {
    # _kv_del <file> <key> — dropping the only line in the file leaves grep with
    # nothing to print, which is exit 1 and not an error here, so the status is
    # swallowed rather than handed to a caller running under `set -e`.
    [ -f "$1" ] || return 0
    grep -v "^$2=" "$1" 2>/dev/null > "$1.new" || :
    mv -f "$1.new" "$1" 2>/dev/null || :
    return 0
}

# --- settings -------------------------------------------------------------
as_get() {
    # as_get <key> [fallback] — the stored value, else the default
    _v=$(_kv_get "$AS_CONF" "$1")
    [ -n "$_v" ] || _v=${2:-$(as_default "$1")}
    echo "$_v"
    unset _v
    return 0
}

# _proc_start <pid> — the process's start time from /proc/<pid>/stat. The comm
# field is wrapped in parentheses and can itself contain spaces, so everything
# up to the last ')' is dropped before counting fields; start time is then the
# 20th.
_proc_start() {
    _ps=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
    _ps=${_ps##*) }
    # shellcheck disable=SC2086
    set -- $_ps
    echo "${20}"
    unset _ps
    return 0
}

# as_notify — tell a running refresh loop that the interval changed, so the new
# one starts counting from now instead of after the old one runs out. Called on
# every interval write, and by hand through `sh as_store.sh reload` after the
# file has been edited outside the module - nothing polls this file.
#
# The loop leaves "<pid> <start time>" in state as `refresh=` and traps CONT. A
# stale file from an earlier boot can name a pid the system has since handed to
# someone else, so the start time has to match too - a pid alone is not an
# identity. CONT is also the one signal whose default action harms nothing, in
# case something slips through anyway (USR1 would terminate it).
as_notify() {
    _line=$(st_get refresh)
    _p=${_line%% *}
    _t=${_line#* }
    [ "$_t" = "$_p" ] && _t=""
    case "$_p" in ''|*[!0-9]*) unset _line _p _t; return 0 ;; esac
    if [ -n "$_t" ] && [ "$_t" != "$(_proc_start "$_p")" ]; then
        unset _line _p _t; return 0
    fi
    kill -CONT "$_p" 2>/dev/null || :
    unset _line _p _t
    return 0
}

# A write goes through as_seed afterwards, so the file keeps one line per
# setting in the order as_default lists them instead of drifting as changed
# keys pile up at the end - this file is meant to be read by a person.
as_set() {
    _kv_set "$AS_CONF" "$1" "$2"
    as_seed
    [ "$1" = interval_sec ] && as_notify
    return 0
}
as_del() { _kv_del "$AS_CONF" "$1"; }

# as_on <key> — true when the feature is on. `as_on auto_fp && do_the_thing`
as_on() { [ "$(as_get "$1")" = "1" ]; }

# as_int <key> [min] — a number, with garbage and anything below the floor
# clamped, so a hand-edited config can never busy-spin a loop.
as_int() {
    _n=$(as_get "$1"); _min=${2:-0}
    case "$_n" in ''|*[!0-9]*) _n=$(as_default "$1") ;; esac
    case "$_n" in ''|*[!0-9]*) _n=$_min ;; esac
    [ "$_n" -lt "$_min" ] && _n=$_min
    echo "$_n"
    unset _n _min
    return 0
}

# as_seed — write the whole set out, every key with its effective value. The
# config file is meant to be read and edited by hand, so it lists every setting
# rather than only the ones that differ from the default: install, first boot and
# a reset each leave a complete file behind. Stored values are kept as they are,
# and a key the file has never had (a setting a later version adds) shows up at
# its default.
as_seed() {
    as_init
    for _k in $AS_KEYS; do
        printf '%s=%s
' "$_k" "$(as_get "$_k")"
    done > "$AS_CONF.new" 2>/dev/null && mv -f "$AS_CONF.new" "$AS_CONF" 2>/dev/null
    chmod 600 "$AS_CONF" 2>/dev/null || :
    unset _k
    return 0
}

# --- internal state -------------------------------------------------------
st_get() { _kv_get "$AS_STATE" "$1"; }
st_set() { _kv_set "$AS_STATE" "$1" "$2"; }
st_del() { _kv_del "$AS_STATE" "$1"; }

# --- scratch space --------------------------------------------------------
# as_tmp <name> — a path under tmp/, created on demand. Callers append $$ when
# they need a per-process file.
as_tmp() { as_init; echo "$AS_TMP/$1"; }

# --- migration ------------------------------------------------------------
# Import the pre-1.0.5 layout: one marker file per toggle, loose logs and state
# in /data/adb/tricky_store. Idempotent and safe to run on every boot — once the
# old files are gone it does nothing. The old names are removed after import so
# the directory actually gets tidier instead of holding both layouts.
as_migrate() {
    _old="$AS_CFG_ROOT"
    [ -d "$_old" ] || return 0

    # marker present = the feature was switched OFF
    for _m in no_auto_fp:auto_fp no_auto_keybox:auto_keybox \
              no_auto_indicator:status_indicator no_rom_spoof_block:rom_spoof_block \
              no_spoof_patch_props:spoof_patch_props no_logcat_cleanup:logcat_cleanup \
              no_prop_unify:prop_unify; do
        if [ -f "$_old/${_m%%:*}" ]; then
            as_set "${_m#*:}" 0
            rm -f "$_old/${_m%%:*}" 2>/dev/null
        fi
    done

    # marker present = the opt-in was switched ON
    for _m in custom_keybox:custom_keybox hide_rom_markers:hide_rom_markers \
              spoof_patch_props:force_patch_props; do
        if [ -f "$_old/${_m%%:*}" ]; then
            as_set "${_m#*:}" 1
            rm -f "$_old/${_m%%:*}" 2>/dev/null
        fi
    done

    if [ -f "$_old/hourly_interval_sec" ]; then
        _iv=$(tr -dc '0-9' < "$_old/hourly_interval_sec" 2>/dev/null)
        [ -n "$_iv" ] && as_set interval_sec "$_iv" ; :
        rm -f "$_old/hourly_interval_sec" 2>/dev/null
        unset _iv
    fi

    # files that keep their shape, only their home changes
    as_init
    for _f in app_keybox.map:apps.map custom_packages:packages spoof.conf:spoof.conf \
              .imported_keyboxes:imported; do
        if [ -f "$_old/${_f%%:*}" ] && [ ! -f "$AS_DIR/${_f#*:}" ]; then
            mv -f "$_old/${_f%%:*}" "$AS_DIR/${_f#*:}" 2>/dev/null || :
        fi
        rm -f "$_old/${_f%%:*}" 2>/dev/null || :
    done

    # loose state files become one key=value file
    for _s in .fp_idx:fp_idx .kb_engine:kb_engine .custom_keybox_name:keybox_name \
              .last_log:last_log; do
        if [ -s "$_old/${_s%%:*}" ]; then
            _sv=$(head -1 "$_old/${_s%%:*}" 2>/dev/null | tr -d '\r')
            [ -n "$_sv" ] && st_set "${_s#*:}" "$_sv" ; :
            unset _sv
        fi
        rm -f "$_old/${_s%%:*}" 2>/dev/null
    done

    for _l in autopif.log:autopif.log .action_boot.log:action-boot.log \
              .action_reset.log:action-reset.log; do
        if [ -f "$_old/${_l%%:*}" ]; then
            mv -f "$_old/${_l%%:*}" "$AS_LOGS/${_l#*:}" 2>/dev/null || :
        fi
        rm -f "$_old/${_l%%:*}" 2>/dev/null || :
    done

    # leftovers from older versions: locks, half-finished downloads, a probe file
    # nothing writes any more
    rm -f "$_old/.action_probe" "$_old/.keybox.sha256" "$_old/.import.pif.prop" \
          "$_old/.ts_loop" "$_old/.teesim_loop" 2>/dev/null
    rm -f "$_old"/.keybox_fetch.* "$_old"/.pif_native.* "$_old"/.pif_asfetch.* \
          "$_old"/.netcheck.* 2>/dev/null
    # and from our own tmp/: the stamp an earlier build polled against, which
    # nothing reads now that the loop is told about a change instead
    rm -f "$AS_TMP/interval.stamp" "$AS_TMP/refresh.pid" 2>/dev/null
    as_seed
    unset _old _m _f _s _l
    return 0
}

# --- command line ---------------------------------------------------------
# The verbs run only when this file is RUN, never when it is sourced: a script
# that sources it passes its own arguments along ("$1" is still the caller's),
# so `sh status_fetch.sh manual` or `sh sync_patch.sh boot` would otherwise be
# read as a verb here. Hence a function plus a $0 check, and no bare return /
# exit, which would either error out or take the sourcing script down with it.
as_cli() {
    case "${1:-}" in
        get)        as_get "$2" "$3" ;;
        set)        as_set "$2" "$3" ;;
        del|unset)  as_del "$2" ;;
        on)         as_on "$2" ;;                  # exit status: 0 = on
        int)        as_int "$2" "$3" ;;
        state-get)  st_get "$2" ;;
        state-set)  st_set "$2" "$3" ;;
        state-del)  st_del "$2" ;;
        path)
            case "$2" in
                dir) echo "$AS_DIR" ;; config) echo "$AS_CONF" ;; state) echo "$AS_STATE" ;;
                apps) echo "$AS_APPS" ;; packages) echo "$AS_PKGS" ;; spoof) echo "$AS_SPOOF" ;;
                imported) echo "$AS_IMPORTED" ;; logs) echo "$AS_LOGS" ;; tmp) echo "$AS_TMP" ;;
                *) echo "$AS_DIR" ;;
            esac ;;
        dump)
            # every setting with its effective value — what the WebUI paints
            # from, in one shell round trip
            for _k in $AS_KEYS; do echo "$_k=$(as_get "$_k")"; done ;;
        reload)     as_notify ;;   # like `nginx -s reload`: tell the loop to re-read
        migrate)    as_init; as_migrate; as_seed ;;
        seed)       as_seed ;;
        init)       as_init ;;
    esac
}

case "$0" in *as_store.sh) as_cli "$@" ;; esac
