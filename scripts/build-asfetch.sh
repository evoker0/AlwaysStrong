#!/usr/bin/env bash
# Cross-compile the AlwaysStrong native HTTPS fetcher for all 4 Android ABIs
# and copy the binaries into native/asfetch/prebuilt/<abi>/asfetch so build.sh
# can pick them up without a Rust toolchain on the build host.
#
# Run this whenever native/asfetch/src/ changes. CI also runs it.
#
# Requires: rustup with the four Android targets installed, cargo-ndk,
#           ANDROID_NDK_HOME pointing at an NDK r25+.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/native/asfetch"
OUT="$SRC/prebuilt"
MIN_API=29   # match MIN_SDK in customize.sh

[[ -n "${ANDROID_NDK_HOME:-}" ]] || {
    echo "ANDROID_NDK_HOME not set" >&2
    exit 1
}
command -v cargo >/dev/null 2>&1 || {
    echo "cargo not on PATH (source ~/.cargo/env?)" >&2
    exit 1
}
command -v cargo-ndk >/dev/null 2>&1 || {
    echo "cargo-ndk not installed (cargo install cargo-ndk)" >&2
    exit 1
}

# Remap absolute build paths so panic-location metadata in the compiled
# binaries can't leak the build machine's username / home dir into a public
# release (otherwise /home/<user>/.cargo/... strings end up in .rodata).
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${CARGO_HOME}=/cargo --remap-path-prefix=${SRC}=/src --remap-path-prefix=${HOME}=/build"

# arm only: asfetch is needed where there's no curl and busybox TLS stalls —
# i.e. real devices. x86/x86_64 are emulator-only (curl/busybox work there),
# so we skip them to keep the shipped zip ~1.9 MB smaller.
echo "==> cross-compiling asfetch (arm64-v8a + armeabi-v7a, API $MIN_API)"
( cd "$SRC" && cargo ndk \
    -t arm64-v8a -t armeabi-v7a \
    --platform "$MIN_API" \
    build --release )

mkdir -p "$OUT"
declare -A MAP=(
    [arm64-v8a]=aarch64-linux-android
    [armeabi-v7a]=armv7-linux-androideabi
)
for abi in "${!MAP[@]}"; do
    rust_target="${MAP[$abi]}"
    src_bin="$SRC/target/$rust_target/release/asfetch"
    [[ -f "$src_bin" ]] || { echo "missing $src_bin" >&2; exit 1; }
    mkdir -p "$OUT/$abi"
    cp -f "$src_bin" "$OUT/$abi/asfetch"
    chmod 755 "$OUT/$abi/asfetch"
done

echo "==> prebuilt binaries:"
( cd "$OUT" && du -h */asfetch )
