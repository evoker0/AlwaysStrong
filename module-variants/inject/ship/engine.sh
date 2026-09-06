#!/system/bin/sh
# Play Integrity engine adapter — PlayIntegrityFix (inject-s).
#
# The shared module scripts never touch a pif file directly; they go through the
# functions here. build.sh overlays exactly one adapter per build, so action.sh,
# service.sh, pif_native_fetch.sh and customize.sh are identical in both.
#
# inject-s reads pif.prop straight from the module dir — no migrate.sh, no
# custom.pif.prop. Its spoof flags are true/false.

ENGINE=inject
ENGINE_NAME="PlayIntegrityFix (inject-s)"

# Upstream files (from the PIF zip) that customize.sh installs.
ENGINE_FILES="autopif.sh security_patch.sh pif.prop"

# Prop files the STRONG flags are enforced on, module dir first.
engine_pif_targets() {
    echo "$MODPATH/pif.prop $CONFIG_DIR/pif.prop"
}

# STRONG spoof defaults, in this engine's naming (inject-s uses true/false).
#   spoofProvider=false      leave the keystore provider alone — TEESimulator
#                            supplies the hardware-attested one STRONG needs.
#   spoofVendingBuild=true   Play Store build spoof (Fork calls this
#                            spoofVendingFinger).
# Any of these can be overridden per-key from the WebUI Advanced tab, which
# writes `key=value` lines into /data/adb/tricky_store/spoof.conf. Some wallet /
# banking apps only pass with a flag flipped (e.g. spoofProps=false on a Poco F8
# Pro). engine_enforce_spoof re-applies these on every boot/hourly pass, so an
# override in spoof.conf survives — without it a flipped flag would silently
# revert an hour after boot.
engine_spoof_defaults() {
    # spoofVendingBuild spoofs the Play Store (Vending) build/fingerprint — the
    # inject-s equivalent of Fork's spoofVendingFinger. On Android 10–12L (device's
    # REAL sdk ≤ 32) it breaks Play Integrity / GMS, so it defaults OFF there; on
    # Android 13+ (sdk 33+) it stays ON. Keyed on the real android version, not the
    # spoofed one. spoof.conf can still override it per device (WebUI Advanced tab).
    _svb=true
    _sdk=$(getprop ro.build.version.sdk 2>/dev/null)
    case "$_sdk" in ''|*[!0-9]*) : ;; *) [ "$_sdk" -le 32 ] && _svb=false ;; esac
    echo "spoofBuild=true spoofProps=true spoofProvider=false spoofSignature=false spoofVendingBuild=$_svb spoofVendingSdk=false DEBUG=false"
}

# Effective value for a spoof key: the spoof.conf override if present, else the
# STRONG default passed in $2.
engine_spoof_val() {
    _ov=$(sed -n "s/^$1=//p" "$CONFIG_DIR/spoof.conf" 2>/dev/null | head -1 | tr -d ' \t\r')
    [ -n "$_ov" ] && echo "$_ov" || echo "$2"
}

# Space-separated key=value list with overrides applied (for engine_enforce_spoof).
engine_spoof_kv() {
    _out=""
    for _kv in $(engine_spoof_defaults); do
        _out="$_out ${_kv%=*}=$(engine_spoof_val "${_kv%=*}" "${_kv#*=}")"
    done
    echo $_out
}

# Same list, one per line — appended to a freshly fetched fingerprint.
engine_spoof_block() {
    for _kv in $(engine_spoof_kv); do echo "$_kv"; done
}

# engine_install_pif SRC — put a fingerprint where the zygisk reads it. The
# config-dir copy is what the WebUI, sync_patch and the status row read.
# Non-zero when this engine can't consume SRC, so callers fall through to the
# next fingerprint source instead of reporting a success that never landed.
engine_install_pif() {
    _src="$1"
    [ -s "$_src" ] || return 1
    mkdir -p "$CONFIG_DIR"
    cp -f "$_src" "$MODPATH/pif.prop" 2>/dev/null
    cp -f "$_src" "$CONFIG_DIR/pif.prop" 2>/dev/null
    # leftovers from a Fork install upgraded in place
    rm -f "$MODPATH/custom.pif.prop" "$MODPATH/custom.pif.json" 2>/dev/null
    [ -s "$MODPATH/pif.prop" ] || return 1
    engine_enforce_spoof
    return 0
}

# engine_autopif — upstream's own fetcher; the fallback when our native crawl
# fails. It writes $MODPATH/pif.prop itself and does not report failure through
# its exit code, so check the file it left behind. 0 on success.
engine_autopif() {
    [ -f "$MODPATH/autopif.sh" ] || return 1
    sh "$MODPATH/autopif.sh"
    grep -q 'FINGERPRINT=google/' "$MODPATH/pif.prop" 2>/dev/null || return 1
    mkdir -p "$CONFIG_DIR"
    cp -f "$MODPATH/pif.prop" "$CONFIG_DIR/pif.prop" 2>/dev/null
    engine_enforce_spoof
    return 0
}

# Apply the STRONG flags to every prop file this engine may read.
engine_enforce_spoof() {
    _sed=${SED_I:-sed -i}
    for _f in $(engine_pif_targets); do
        [ -f "$_f" ] || continue
        for _kv in $(engine_spoof_kv); do
            _k="${_kv%=*}"; _v="${_kv#*=}"
            if grep -qE "^${_k}=" "$_f"; then
                $_sed "s|^${_k}=.*|${_k}=${_v}|" "$_f"
            else
                echo "${_k}=${_v}" >> "$_f"
            fi
        done
    done
}

# Seconds before the native crawl / upstream fetcher are killed. The crawl runs
# ~20-25s on a cold network, so 25 grazes it and forces the fallback every tap.
ENGINE_NATIVE_TIMEOUT=60
ENGINE_AUTOPIF_TIMEOUT=60
