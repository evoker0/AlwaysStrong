#!/system/bin/sh
# Play Integrity engine adapter — NONE (PIF-less "Lite" line).
#
# This build ships no PlayIntegrityFork / PlayIntegrityFix zygisk. The shared
# module scripts still source this file and call the engine_* functions, so they
# are all defined here as clean no-ops. The TEESimulator / TrickyStoreOSS
# attestation engine and the keybox fetcher are unaffected — they live in
# attest.sh and keybox_fetch.sh, not here.
#
# Consumers gate their fingerprint work on ENGINE=none, so no fingerprint is
# fetched, spoofed, or reported on this line.

ENGINE=none
ENGINE_NAME="PIF-less (no fingerprint spoof)"

# No upstream Play Integrity files to install.
ENGINE_FILES=""

engine_pif_targets()   { echo ""; }
engine_spoof_kv()      { echo ""; }
engine_spoof_block()   { :; }
# No zygisk consumes a fingerprint on the Lite line, so nothing spoofs android.os.Build.
# The attestation engine still can: TEESimulator reads device identity (brand / model /
# device / product / security patch) from the pif to keep its attested device consistent.
# So an imported fingerprint is persisted to the canonical pif.prop — that lets the WebUI
# "Import fingerprint" feature drive teesim's identity on a Lite build, instead of failing.
engine_install_pif()   {
    [ -s "$1" ] || return 1
    cp -f "$1" "${CONFIG_DIR:-/data/adb/tricky_store}/pif.prop" 2>/dev/null || return 1
    return 0
}
engine_autopif()       { return 1; }
engine_enforce_spoof() { return 0; }

ENGINE_NATIVE_TIMEOUT=10
ENGINE_AUTOPIF_TIMEOUT=10
