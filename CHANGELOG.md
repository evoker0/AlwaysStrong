# AlwaysStrong changelog

## v1.0.4

**Bug fixes — custom ROMs (LineageOS, crDroid, …)**
- **ROM version no longer shows "unknown".** The module was deleting `ro.modversion` / `ro.lineage.*` device-wide, which is what Settings → About phone reads. Play Integrity doesn't rely on those props, so they are now preserved by default and Settings shows the real ROM version again.
- **Fast-charging toggle restored on LineageOS.** The module deleted `init.svc.vendor.lineage_health`, which made Settings hide the fast-charging / charge-control switch. It is left alone by default now (issue #7).
- **Security patch follows OTA again.** The spoofed patch date is no longer forced onto the global system props, so Settings shows the real patch level and it updates after an OTA. The attestation and the per-app spoof still stay in lock-step with the fingerprint, so STRONG is unaffected.
- These three aggressive hides are still available as opt-in toggles in the new **Advanced** tab for anyone who wants maximum stealth.

**New — WebUI**
- **Advanced tab** with **Import fingerprint** (load your own `pif.json` or `pif.prop` — issue #17) and **Spoof variables**: a live toggle for every PlayIntegrity spoof flag by its real name (`spoofProps`, `spoofBuild`, `spoofProvider`, `spoofVendingFinger`/`spoofVendingBuild`, `spoofSignature`, `spoofVendingSdk`, `DEBUG`). Flip one only if an app needs it (e.g. `spoofProps` off for some wallet apps); the change is written as an override that survives the hourly re-apply, and the STRONG defaults hold otherwise.
- **Target apps menu** (⋮, top-right): **Add custom package** (type any package id — e.g. a system app that runs an integrity check), **Select all**, and **Unselect unnecessary** (deselects root managers and apps that don't check the bootloader, using Tricky-Addon's exclusion list).
- **Lite builds drive your own PIF.** On a Lite (`-nopif`) build the Advanced spoof toggles now edit a standalone **PlayIntegrityFork** or **PlayIntegrityFix (inject-s)** that you installed yourself — the module detects which one you have and keeps its fingerprint and STRONG flags in sync. With no such module present it stays attestation + keybox only, as before.

**New — builds**
- **PIF-less "Lite" build** (`-nopif`) for setups where the bundled PlayIntegrityFork conflicts with Google Play Services — keeps hardware attestation + the automated keybox, drops the fingerprint spoof.
- **Third keystore engine: TEESimulator (JingMatrix)** (`-TEESIM`), alongside TEESimulator-RS and TrickyStoreOSS. Every release now ships the full 3×3 matrix (Fork / inject / Lite × the three keystores). On the **Fork and inject** lines `-TEESIM` reaches `STRONG` — verified on a device whose real TEE keystore is unavailable, exactly the case the other engines were added for. Two things make it work: the target list handed to TEESimulator is now sanitised (TrickyStore's `pkg!` / `[keybox]` syntax is stripped and GMS/Vending/GSF are pinned by raw `uid:` so DroidGuard's `generateKey` is always claimed instead of falling through to the real HAL), and the profile runs in **generation** mode (the whole key is minted in software under the keybox, so it no longer needs a working hardware KeyMint level). On the **Lite** line, where nothing spoofs `android.os.Build`, TEESimulator must attest the device's *real* identity to match — pointing it at a Pixel fingerprint there mismatches the real Build and lands at `BASIC`, so Lite + `-TEESIM` is for devices whose real keybox-backed attestation already passes.
- Upstream releases now **auto-publish**: when PlayIntegrityFork / PlayIntegrityFix / TEESimulator(-RS) move, CI bumps the version, writes English notes, and cuts a release on its own.

**Upstream**
- Updated PlayIntegrityFork to v18.
- Updated TrickyStoreOSS to v3.1.0.
- Added TEESimulator (JingMatrix) canary-63 as a keystore option.

**Fixes**
- Uninstalling a Lite build no longer removes a standalone PlayIntegrityFork / PlayIntegrityFix you installed yourself (both share the `playintegrityfix` module id).
- Importing your own fingerprint now also updates the TEESimulator (JingMatrix) profile, so `-TEESIM` builds don't briefly drop to `BASIC` after an import.

## v1.0.3

- Added a second build, `-inject`, running on PlayIntegrityFix inject-s. A lot of you asked for it. Try it if the default doesn't reach STRONG on your device.
- Per-app keybox: assign a different keybox to specific apps from the WebUI, instead of one keybox for everything. Import your own keybox files, pick which app gets which, and the rest keep using the default — handy when one app needs a separate key.
- Collect logs button in the WebUI (also `sh action.sh logs`) that saves a diagnostic report to `/sdcard` for issue reports.
- Updated TEESimulator-RS to v6.0.1-307.
- Bug fixes.

## v1.0.2

New keybox mirror, a far more reliable fetcher, a custom-keybox file picker in the WebUI, strong-integrity fixes, and a faster, steadier Action.

**Strong integrity**
- **The fingerprint reaches PlayIntegrityFork.** PIF's zygisk reads `custom.pif.prop` from the module dir; every fetch path — native, autopif4, and the shipped fallback — now runs `migrate.sh` to produce that file and enforces the STRONG spoof settings (`spoofProvider=0`, `spoofVendingFinger=1`), so STRONG holds with a valid keybox (3 green).
- **Strong survives the hourly refresh.** The hourly fingerprint refresh regenerated `custom.pif.prop` but skipped re-applying the STRONG spoof settings, so ~1 h after boot the fingerprint silently reverted to a weak config (`spoofProvider=1`, `spoofVendingFinger=0`) and STRONG dropped even though the WebUI still showed 3 green. The native fetch now enforces the STRONG settings itself, and the hourly loop re-enforces them, so every refresh stays strong.
- **Faster fingerprint.** The fast native crawl (~10s) is primary; autopif4 — whose crawl stalls up to ~1 min on some devices — is the fallback.

**ROM spoof**
- The disable list now matches PlayIntegrityFork's current engines (adds `persist.sys.pp.*`, plus AOSPA / PixelOS / Afterlife detection). Uninstalling AlwaysStrong now restores the ROM's own spoof engines — the persist props it set are cleared on uninstall (only if still unchanged), so removing the module frees PixelProps / pihooks / entryhooks again.

**Keybox & status**
- Moved to the new mirror: keybox from `http://evoker.qzz.io/key`, status from `/status`.
- The WebUI status now shows which keybox is in use (e.g. `evokerrkey27`) alongside the health.

**Custom keybox (WebUI)**
- New "Custom keybox" toggle — use your own keybox instead of the auto one.
- Built-in file manager to pick a keybox from storage: breadcrumb path, folder navigation, file size + date, and sort (name / newest / oldest).
- While custom keybox is on, the module stops auto-fetching (Action shows "custom keybox — skip fetch").

**Fingerprint**
- The fingerprint is now fetched by a native crawl of the same Google servers PlayIntegrityFork uses — fast and reliable on devices where autopif4's busybox-wget crawl used to hang. autopif4 is kept as a bounded fallback, and shipped static fingerprints guarantee one always lands.
- The Action never shows a bare "offline": a failed primary is shown once as "trying with fallback", and it drops through quickly (bounded timeouts).

**Fetcher (asfetch)**
- Rewritten to connect IPv4-first — fixes "keybox missing" and stuck downloads on networks that advertise IPv6 in DNS but have no working IPv6 route.
- Handles http + https, redirects, chunked responses, and custom request headers.
- Every download (keybox, status, fingerprint crawl, WebUI) falls back across asfetch → busybox wget → curl → wget, so it works on every device.

**Misc**
- Removed the "recheck in ~1 min" line from the Action output.

## v1.0.1

Hotfix, same upstream as v1.0.0.

- Added a native fetcher (Rust/rustls) so the keybox downloads on every device — busybox's TLS was stalling on the mirror.
- Action button no longer hangs, and it stops force-enabling Magisk's Enforce DenyList.
- Smaller banner / lighter zip.

## v1.0.0

Initial release.

- Bundles TEESimulator-RS v6.0.1-282 (Rust TEE simulator, hardware attestation injection)
- Bundles PlayIntegrityFork v17 (zygisk Build/property spoofing for GMS DroidGuard)
- Installer removes conflicting standalone modules (TrickyStore, PIF, USNF, MHPC, etc.)
- Bootloader / verified-boot prop spoofing in `post-fs-data.sh`
- Late OEM-specific prop spoofing in `service.sh` (Samsung, Realme, OnePlus, Xiaomi, Oppo)
- Action button refreshes fingerprint via `autopif4` and restarts PI processes via `killpi`
- Optional keybox auto-fetch (`keybox_fetch.sh`) — set `KEYBOX_URL` to any raw HTTPS URL
- Daemon classpath renamed to `tee_classes.dex` so PIF zygisk's `classes.dex` lookup doesn't collide
- `build.sh` / `build.ps1` download pinned upstream release ZIPs and repackage — rebuild on any upstream release by bumping the version variables
