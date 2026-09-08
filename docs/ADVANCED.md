# AlwaysStrong — advanced: optional engines, building, repo layout

Everything on this page is optional. The three release zips on the
[Releases](https://github.com/evoker0/AlwaysStrong/releases/latest) page are what
almost everyone should install — see **Which build to download** in the
[README](../README.md).

## Optional keystore engines (`-TSOSS`, `-TEESIM`)

The release zips fake hardware key attestation with **TEESimulator-RS**. Two
alternative keystore engines are wired into the same module and can be built for
any of the three Play Integrity lines (Fork / inject / Lite). They are **never
attached to releases** — they live in the nightly builds:

- **Nightly builds (direct download)** — every nightly run builds all nine zips,
  each as its own artifact. The **latest** build of any line is always at a
  permanent [nightly.link](https://nightly.link/evoker0/AlwaysStrong/workflows/nightly/main)
  URL, no GitHub login needed:

  | Line | Latest nightly |
  |---|---|
  | Fork + TEESimulator-RS | [AlwaysStrong-fork.zip](https://nightly.link/evoker0/AlwaysStrong/workflows/nightly/main/AlwaysStrong-fork.zip) |
  | inject + TEESimulator-RS | [AlwaysStrong-inject.zip](https://nightly.link/evoker0/AlwaysStrong/workflows/nightly/main/AlwaysStrong-inject.zip) |
  | Lite + TEESimulator-RS | [AlwaysStrong-nopif.zip](https://nightly.link/evoker0/AlwaysStrong/workflows/nightly/main/AlwaysStrong-nopif.zip) |
  | Fork + TrickyStoreOSS | [AlwaysStrong-TSOSS.zip](https://nightly.link/evoker0/AlwaysStrong/workflows/nightly/main/AlwaysStrong-TSOSS.zip) |
  | inject + TrickyStoreOSS | [AlwaysStrong-inject-TSOSS.zip](https://nightly.link/evoker0/AlwaysStrong/workflows/nightly/main/AlwaysStrong-inject-TSOSS.zip) |
  | Lite + TrickyStoreOSS | [AlwaysStrong-nopif-TSOSS.zip](https://nightly.link/evoker0/AlwaysStrong/workflows/nightly/main/AlwaysStrong-nopif-TSOSS.zip) |
  | Fork + TEESimulator (JingMatrix) | [AlwaysStrong-TEESIM.zip](https://nightly.link/evoker0/AlwaysStrong/workflows/nightly/main/AlwaysStrong-TEESIM.zip) |
  | inject + TEESimulator (JingMatrix) | [AlwaysStrong-inject-TEESIM.zip](https://nightly.link/evoker0/AlwaysStrong/workflows/nightly/main/AlwaysStrong-inject-TEESIM.zip) |
  | Lite + TEESimulator (JingMatrix) | [AlwaysStrong-nopif-TEESIM.zip](https://nightly.link/evoker0/AlwaysStrong/workflows/nightly/main/AlwaysStrong-nopif-TEESIM.zip) |

  What you download is the module zip itself — flash it as-is, no unpacking
  (the version is in its `module.prop`). The same artifacts are on the
  [Actions tab](https://github.com/evoker0/AlwaysStrong/actions/workflows/nightly.yml)
  under the latest run (GitHub login required there). Nightlies are untested
  snapshots of `main` and are kept for 30 days.
- **Build locally** — `./build.sh --engine trickystoreoss` or `./build.sh --engine teesim`
  (see *Building* below).

| Zip | PI engine | Keystore | Notes |
|---|---|---|---|
| `AlwaysStrong-<ver>-TSOSS.zip` | PlayIntegrityFork | [TrickyStoreOSS](https://github.com/beakthoven/TrickyStoreOSS) | Open-source TrickyStore keystore. Reads the same `/data/adb/tricky_store/`. |
| `AlwaysStrong-<ver>-inject-TSOSS.zip` | PlayIntegrityFix (inject-s) | TrickyStoreOSS | inject-s **and** TrickyStoreOSS. |
| `AlwaysStrong-<ver>-nopif-TSOSS.zip` | none (Lite) | TrickyStoreOSS | Lite on TrickyStoreOSS. |
| `AlwaysStrong-<ver>-TEESIM.zip` | PlayIntegrityFork | [TEESimulator (JingMatrix)](https://github.com/JingMatrix/TEESimulator) | The original TEESimulator. 64-bit only. |
| `AlwaysStrong-<ver>-inject-TEESIM.zip` | PlayIntegrityFix (inject-s) | TEESimulator (JingMatrix) | inject-s **and** the JingMatrix TEESimulator. |
| `AlwaysStrong-<ver>-nopif-TEESIM.zip` | none (Lite) | TEESimulator (JingMatrix) | Lite on the JingMatrix TEESimulator — read the note below. |

Notes:

- **Install only one AlwaysStrong zip at a time.** Switching means flashing the other zip over the top.
- **No auto-update.** Only the three release zips carry an `updateJson`. `-TSOSS` / `-TEESIM` are manual downloads — grab a new one when you want it.
- **ABI:** the `-TEESIM` builds are **64-bit only** (arm64-v8a / x86_64); on a 32-bit device they install but the keystore half stays inactive. As on the release zips, PlayIntegrityFix inject-s has no x86 zygisk, so `-inject*` can't spoof Play Integrity on x86.
- **`-TEESIM` on Fork / inject reaches `STRONG`.** The JingMatrix TEESimulator uses its own `/data/adb/teesim/config.json`; AlwaysStrong bridges the keybox, the target-app list and the PIF-spoofed device identity into it automatically (regenerated from `target.txt` + the active pif at boot and hourly). The target list is sanitised into TEESimulator's own format (TrickyStore's `pkg!` / `[keybox]` syntax stripped), GMS / Vending / GSF are pinned by raw `uid:` so their Play Integrity `generateKey` is always claimed by the interceptor, and the profile runs in **generation** mode so it works even where the device's real TEE keystore is unavailable. Verified `STRONG` on such a device.
- **`-TEESIM` on Lite is different.** The Lite line spoofs nothing in `android.os.Build`, so TEESimulator has to attest the device's *real* identity — importing a Pixel fingerprint there makes the attested device mismatch the real Build and drops the verdict to `BASIC`. Use Lite + `-TEESIM` only on a device whose real, keybox-backed attestation already passes; otherwise pick a Fork or inject `-TEESIM` build.

## Building

The repo ships no upstream binaries. `build.sh` downloads the pinned upstream
release ZIPs, overlays the glue scripts in `module/`, and produces the
installable ZIPs. On Windows run it from WSL or Git Bash (7-Zip is used
automatically when Info-ZIP `zip` is missing). Requires bash, curl or wget,
unzip, zip, sha256sum.

```bash
./build.sh                              # the three release zips (Fork / inject / Lite on TEESimulator-RS)
./build.sh --variant fork               # only the default (Fork) build
./build.sh --variant inject             # only the -inject build
./build.sh --variant nopif              # only the PIF-less Lite build
./build.sh --engine trickystoreoss      # the three lines on TrickyStoreOSS (-TSOSS)
./build.sh --engine teesim              # the three lines on TEESimulator/JingMatrix (-TEESIM)
./build.sh --clean                      # wipe build/ and rebuild
./build.sh --tee v6.0.1-307             # override the TEESimulator-RS tag
```

Output lands in `out/`:

- `AlwaysStrong-<version>.zip` / `-inject.zip` / `-nopif.zip` — TEESimulator-RS (the release set)
- `AlwaysStrong-<version>-TSOSS.zip` / `-inject-TSOSS.zip` / `-nopif-TSOSS.zip` — TrickyStoreOSS
- `AlwaysStrong-<version>-TEESIM.zip` / `-inject-TEESIM.zip` / `-nopif-TEESIM.zip` — TEESimulator (JingMatrix)

### Keystore engines

The keystore backend is chosen with `--engine`:

- **`tee`** — [TEESimulator-RS](https://github.com/Enginex0/TEESimulator-RS) (default, Rust port). Reads `/data/adb/tricky_store/`.
- **`trickystoreoss`** — the open-source [TrickyStoreOSS](https://github.com/beakthoven/TrickyStoreOSS). Also reads `/data/adb/tricky_store/`. `-TSOSS` suffix.
- **`teesim`** — the original [TEESimulator by JingMatrix](https://github.com/JingMatrix/TEESimulator) (Kotlin control daemon + native KeyMint interceptor). Uses its own `/data/adb/teesim/config.json`; `attest/teesim.sh` bridges the shared keybox + target list into it. 64-bit only. `-TEESIM` suffix.

To build an engine from a local upstream ZIP instead of the pinned download:

```bash
./build.sh --engine trickystoreoss --tsoss-file Tricky-Store-OSS-v3.1.0-...-Release.zip
./build.sh --engine teesim --teesim-file TEESimulator-v4.0-...-Release.zip
./build.sh --variant fork --pif-file PlayIntegrityFork-v18.zip
```

### Repo layout

All lines are built from this one tree — there is no second branch:

```
module/                                 everything the lines share
module-variants/<line>/build.conf       upstream pin + which files to lift
module-variants/<line>/module.prop.override
module-variants/<line>/ship/engine.sh   the only Play-Integrity-engine-specific script
attest/<engine>.sh                      the keystore-engine adapter (copied in as attest.sh)
native/asfetch                          the Rust/rustls fetcher (prebuilt binaries committed)
native/watcher                          the inotify target-list watcher (prebuilt committed)
```

`engine.sh` is the whole seam between Play Integrity engines. It answers three
questions the rest of the module never has to care about: which prop file this
engine's zygisk reads, what its STRONG spoof flags are called, and how upstream's
own fingerprint fetcher is invoked. Adding another engine means adding one
directory, not a branch. `attest.sh` is the same seam for the keystore side.

`version` / `versionCode` live only in `module/module.prop` — a line may not
override them, so the builds can never disagree about which release they are.

### Native binaries

`build.sh` packages the committed prebuilt binaries as they are unless a Rust
toolchain with `cargo-ndk` and an Android NDK is present *and* the sources are
newer. After editing `native/asfetch/src`, either run `scripts/build-asfetch.sh`
locally or run the **Native binaries** workflow from the Actions tab (tick
*commit* to push the rebuilt prebuilts to `main`). The release and nightly
workflows never compile — they ship what is committed.

## Upstream updates

To pull upstream and repackage in one go:

```bash
scripts/update-upstream.sh --apply --build
```

That bumps TEESimulator-RS in `build.sh` and each line's Play Integrity engine in
its own `build.conf` to the newest upstream release — **prereleases included**,
which is where TEESimulator-RS publishes its freshest builds — and rebuilds.
Drop `--build` to only bump, add `--stable-only` to ignore prereleases.

A weekly GitHub Action (`upstream-auto-release`) runs the same check and, when
TEESimulator-RS or a line's Play Integrity engine moved, **auto-releases**: it
bumps the module by one patch version (e.g. `v1.0.4` → `v1.0.5`), writes an
English changelog entry describing exactly what updated, rebuilds the three
release zips, and publishes a GitHub release. When only the optional engines
(TrickyStoreOSS / TEESimulator) move, their pins are refreshed and committed but
no release is cut.
