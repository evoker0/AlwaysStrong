<div align="center">

<img src="banner.png" alt="AlwaysStrong" width="700">

<br>
<br>

[![Release](https://img.shields.io/github/v/release/evoker0/AlwaysStrong?color=2ea043&label=release)](https://github.com/evoker0/AlwaysStrong/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/evoker0/AlwaysStrong/total?color=2ea043)](https://github.com/evoker0/AlwaysStrong/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-orange)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-keyboxstrong-26A5E4?logo=telegram&logoColor=white)](https://t.me/keyboxstrong)

<img src="screenshots/webui.jpg" width="44%" alt="WebUI"> &nbsp; <img src="screenshots/languages.jpg" width="44%" alt="Translated into 15 languages">

<sub>Built-in WebUI on KernelSU / APatch — hourly auto-update toggles, translated into 15 languages.</sub>

</div>

# AlwaysStrong

One-flash `STRONG` Play Integrity for Magisk / KernelSU / APatch. It bundles [TEESimulator-RS](https://github.com/Enginex0/TEESimulator-RS) and [PlayIntegrityFork](https://github.com/osm0sis/PlayIntegrityFork) into a single module so you don't have to stack and wire them up yourself.

To use this module you need one of the following (latest versions), with a Zygisk implementation installed:

- [Magisk](https://github.com/topjohnwu/Magisk) with Zygisk enabled — a standalone [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) / [ReZygisk](https://github.com/PerformanC/ReZygisk) / [NeoZygisk](https://github.com/JingMatrix/NeoZygisk) is recommended over Magisk's built-in Zygisk, which is more easily detected
- [KernelSU](https://github.com/tiann/KernelSU) or [KernelSU Next](https://github.com/KernelSU-Next/KernelSU-Next) with [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) or [ReZygisk](https://github.com/PerformanC/ReZygisk) or [NeoZygisk](https://github.com/JingMatrix/NeoZygisk) module installed
- [APatch](https://github.com/bmax121/APatch) with [Zygisk Next](https://github.com/Dr-TSNG/ZygiskNext) or [ReZygisk](https://github.com/PerformanC/ReZygisk) or [NeoZygisk](https://github.com/JingMatrix/NeoZygisk) module installed

Android 10+ (SDK 29) is required.

## Join group / channel

- Channel: [t.me/keyboxstrong](https://t.me/keyboxstrong)
- Root community: [t.me/evokeroot](https://t.me/evokeroot)
- Chat / support group: [t.me/keyboxstrongchat](https://t.me/keyboxstrongchat)

## Support

If AlwaysStrong is useful to you, you can tip at [coindrop.to/evokerrr](https://coindrop.to/evokerrr).

<a href="https://www.buymeacoffee.com/evokerr" target="_blank">
  <img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=%E2%98%95&slug=evokerr&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff" alt="Buy Me A Coffee" />
</a>

## Installation

1. Install a Zygisk implementation (Zygisk Next / ReZygisk / NeoZygisk).
2. Download the latest ZIP from [Releases](https://github.com/evoker0/AlwaysStrong/releases/latest).
3. Flash it in your root manager and reboot.
4. Open the module and tap **Action**.
5. Check your verdict with a checker (Play Integrity API Checker, YASNAC, Simple PIC).

The first Action tap fetches a working keybox and a fresh Pixel fingerprint and restarts Play Integrity, so there is no manual keybox step. The installer also removes conflicting standalone modules at install time (TrickyStore, PlayIntegrityFix/Fork, TEESimulator, playcurl/playcurlNEXT, SafetyNet Fix, MagiskHidePropsConf, Tricky Addon, Yurikey, and a few others).

### Which build to download

**If you're not sure, download `AlwaysStrong-<version>.zip` — the plain one with no suffix.** It's the default and passes `STRONG` on most devices.

Every release ships three zips. They differ only in how the Pixel fingerprint is spoofed; all three use the same TEESimulator-RS keystore and the same automated keybox.

| Download | Play Integrity engine | Choose it when |
|---|---|---|
| `AlwaysStrong-<ver>.zip` | PlayIntegrityFork | **Default — start here.** |
| `AlwaysStrong-<ver>-inject.zip` | PlayIntegrityFix (inject-s) | The default doesn't reach `STRONG` on your device. |
| `AlwaysStrong-<ver>-nopif.zip` | **none (Lite)** | The bundled PIF conflicts with Google Play Services (Play Store crashes, "couldn't load" account screen, missing-dependency errors). You keep hardware attestation + the automated keybox, but there is **no fingerprint spoof** — bring your own PlayIntegrityFork / Fix if you need one; the module detects it and keeps it in sync. |

- **Install only one at a time.** Switching builds means flashing the other zip over the top.
- **Auto-update:** all three update themselves in place through your root manager.
- **ABI:** every build installs on arm64-v8a, armeabi-v7a, x86 and x86_64, but PlayIntegrityFix inject-s has no x86 zygisk — on x86 / x86_64 the `-inject` build can't spoof Play Integrity (it says so at install). On x86 use the default or the Lite build.

<details>
<summary><b>Optional keystore engines: TrickyStoreOSS (<code>-TSOSS</code>) and TEESimulator by JingMatrix (<code>-TEESIM</code>)</b></summary>

The keystore half can also run on the open-source [TrickyStoreOSS](https://github.com/beakthoven/TrickyStoreOSS) or on the original [TEESimulator by JingMatrix](https://github.com/JingMatrix/TEESimulator), for any of the three lines above (`-TSOSS`, `-inject-TSOSS`, `-nopif-TSOSS`, `-TEESIM`, `-inject-TEESIM`, `-nopif-TEESIM`). These are **nightly-only, never in a release**: download the latest nightly of each one straight from the [nightly.link table in ADVANCED.md](docs/ADVANCED.md#optional-keystore-engines--tsoss--teesim) (one artifact per variant), or build them yourself with `./build.sh --engine trickystoreoss` / `--engine teesim`. They don't auto-update, and `-TEESIM` is 64-bit only.

Details, caveats (in particular Lite + `-TEESIM`) and how to build them: **[docs/ADVANCED.md](docs/ADVANCED.md)**.

</details>

## Features

- **One flash, `STRONG`.** TEESimulator-RS + PlayIntegrityFork in a single module. No stacking, no manual wiring.
- **Keybox on tap.** The first **Action** fetches a working keybox automatically.
- **A fingerprint that never goes stale.** Every Action pulls a fresh Pixel fingerprint and matching security patch, and a background service does the same **every hour** (interval configurable, each toggle-able from the WebUI).
- **Hands-off keybox too.** The hourly service re-checks the keybox and only swaps it in when a newer one is available.
- **Auto target.** A native watcher follows package changes via inotify: install a new app and it's added to the attestation target instantly.
- **Xposed-aware.** LSPosed / Xposed managers are kept out of the target list, since attesting through a hooked process breaks `STRONG`.
- **Conflict resolution.** Known conflicting modules (TrickyStore, other PIF / TEE forks, SafetyNet Fix, MagiskHidePropsConf, …) are disabled at install and on every boot.
- **WebUI Advanced tab.** Import your own fingerprint (`pif.json` / `pif.prop`), flip any Play Integrity spoof flag by its real name, add custom target packages, or switch to your own keybox.

<details>
<summary><b>More: GMS kill, security-patch sync, one clean module</b></summary>

- **GMS kill.** Force-stops DroidGuard (`com.google.android.gms.unstable`) and clears the Play Store on each refresh, so a new fingerprint or keybox takes effect without a reboot.
- **Security-patch sync.** Keeps the OS / vendor / boot security-patch levels reported in attestation aligned with the spoofed fingerprint.
- **One clean module.** PIF is binary-patched to run inside `tricky_store` — it never litters a separate `playintegrityfix` folder under `/data/adb/modules`.
- **Lite builds drive your own PIF.** On a `-nopif` build the Advanced spoof toggles edit a standalone PlayIntegrityFork / PlayIntegrityFix you installed yourself, and its fingerprint is mirrored into the attested identity.

</details>

<details>
<summary><b>About the module: how the two halves are glued together</b></summary>

AlwaysStrong is two parts merged into one module:

- **TEESimulator-RS** intercepts Binder IPC inside the `keystore2` process and builds full attestation certificate chains from your keybox, so apps that verify hardware key attestation see a legitimate TEE. It is not a fork of TrickyStore; it reuses the same `/data/adb/tricky_store` config layout for drop-in compatibility, but the internals (native Rust certgen, `lsplt` interception, key persistence) are different.
- **PlayIntegrityFork** injects a `classes.dex` to modify `android.os.Build` fields and hooks native code to spoof system properties, only to Google Play Services' DroidGuard (Play Integrity).

TEESimulator's `classes.dex` is renamed to `tee_classes.dex` so it doesn't collide with PIF's, and PIF's hardcoded module paths are binary-patched to point at `/data/adb/modules/tricky_store` — it never creates a separate `playintegrityfix` folder. The module id stays `tricky_store` so existing tooling and tutorials keep working unchanged.

</details>

## The Action button

Triggered from your root manager, or by running `sh action.sh` in a root shell. Each tap rebuilds `target.txt`, refreshes the keybox, pulls a fresh Pixel fingerprint and security patch, and restarts DroidGuard and the Play Store. The verdict updates a few seconds later; no reboot is needed. Every network step is hard-bounded, so a dead network shows "trying with fallback" and the Action still finishes — it never sits on a blank screen.

The same refresh also runs on its own in the background every hour (interval configurable from the WebUI), so the module keeps passing with zero manual upkeep.

## Configuration

All config files live at `/data/adb/tricky_store/` and are reloaded automatically when changed. The Action button keeps them current, so most users never need to touch these.

- **`keybox.xml`** — the attestation keybox, fetched automatically on the first Action tap. To use your own, switch on *Custom keybox* in the WebUI (or place the file here) and it won't be overwritten. To point the auto-refresh at a different mirror, set `KEYBOX_BASE_URL` for `keybox_fetch.sh`; the script validates the payload before replacing the current file.

## Building

```bash
./build.sh                          # the three release zips (Fork / inject / Lite)
./build.sh --variant fork           # just one line
./build.sh --engine trickystoreoss  # optional: the -TSOSS keystore engine
```

`build.sh` downloads the pinned upstream release ZIPs, overlays the glue scripts in `module/`, and produces the installable ZIPs (on Windows run it from WSL or Git Bash). Engines, repo layout, native binaries and the upstream auto-release: **[docs/ADVANCED.md](docs/ADVANCED.md)**.

## Credits

<div align="center">
<img src="screenshots/built-on.png" alt="AlwaysStrong stands on the shoulders of TEESimulator-RS and PlayIntegrityFork" width="600">
</div>

AlwaysStrong is combine of TEE-Simulator-RS + Play Integrity Fork

- [JingMatrix](https://github.com/JingMatrix/TEESimulator) — original TEESimulator and keystore2 interception
- [Enginex0](https://github.com/Enginex0/TEESimulator-RS) — TEESimulator-RS (Rust port, native certgen, AOSP-spec attestation)
- [5ec1cff](https://github.com/5ec1cff/TrickyStore) — TrickyStore, which pioneered keystore interception and the config-dir layout reused here
- [beakthoven](https://github.com/beakthoven/TrickyStoreOSS) — TrickyStoreOSS, the open-source keystore engine offered as a self-build option
- [chiteroman](https://github.com/chiteroman) — original Play Integrity Fix
- [osm0sis](https://github.com/osm0sis/PlayIntegrityFork) — PlayIntegrityFork, the maintained fork bundled here
- [Displax](https://github.com/Displax/safetynet-fix) — module boot scripts forked into PIF
- [daboynb](https://github.com/daboynb/playcurlNEXT) — fingerprint auto-refresh approach
- [LSPlt](https://github.com/LSPosed/LSPlt) (PLT hooks) and [ring](https://github.com/briansmith/ring) (Rust crypto)
- [KOWX712](https://github.com/KOWX712) — PlayIntegrityFix (inject-s), used by the `-inject` build, and KsuWebUIStandalone

Packaging by [@evokerr](https://t.me/evokerr).

## License

GPL-3.0. AlwaysStrong bundles TEESimulator-RS (GPL-3.0), which makes the combined distribution GPL-3.0. See [LICENSE](LICENSE) and the upstream repos for full terms. Provided as-is, with no warranty; `STRONG` depends on a non-revoked hardware keybox, which the module cannot mint for you.
