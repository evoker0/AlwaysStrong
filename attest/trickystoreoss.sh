#!/system/bin/sh
# Attestation-engine adapter — TrickyStoreOSS (beakthoven, --engine trickystoreoss).
#
# The open-source TrickyStore. Unlike the 5ec1cff build it ships a plain
# classes.dex + a per-arch libinject.so (no obfuscated machikado/mazoku, no
# .sha256 anti-tamper manifest), so it drops in the way the TEE engine does. It
# reads the same /data/adb/tricky_store/ config the shared scripts manage.
#
# build.sh renames its classes.dex to tsoss_classes.dex (so it coexists with
# PIF's classes.dex) and ships a daemon that loads that path.

ATTEST=trickystoreoss
ATTEST_NAME="TrickyStoreOSS"

# Injects into keystore2 at the service stage (before sys.boot_completed), like
# upstream — a late start misses the window. service.sh honours attest_early.
attest_early() { return 0; }

attest_install() {
    install_file "lib/$ABI_DIR/libTrickyStoreOSS.so" "$MODPATH"
    install_file "lib/$ABI_DIR/libinject.so"         "$MODPATH"
    mv "$MODPATH/libinject.so" "$MODPATH/inject"
    install_file "tsoss_classes.dex" "$MODPATH"
    chmod 755 "$MODPATH/inject" "$MODPATH/daemon" 2>/dev/null
    ui_print "TrickyStoreOSS installed ($ABI_DIR)"
}

# app_process daemon loop (the daemon takes $MODDIR as $1). Idempotent via a
# loop-pid marker so the early start and the watchdog don't stack parallel loops
# (they would fight over the keystore2 injection).
attest_start() {
    _lk=/data/adb/tricky_store/.ts_loop
    if [ -f "$_lk" ] && kill -0 "$(cat "$_lk" 2>/dev/null)" 2>/dev/null; then
        return 0
    fi
    ( cd "$MODDIR" || exit 1
      while true; do
          ./daemon "$MODDIR" || break
          sleep 2
      done ) &
    echo $! > "$_lk" 2>/dev/null
}

attest_alive() { pidof TrickyStoreOSS >/dev/null 2>&1; }

# keybox.xml / target.txt changed. TrickyStoreOSS watches /data/adb/tricky_store
# itself, so there is nothing to poke.
attest_notify() { return 0; }
