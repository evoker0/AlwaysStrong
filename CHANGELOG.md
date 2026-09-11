# AlwaysStrong changelog

## Unreleased

**New**
- **Releases are verifiable.** Every release now carries a `SHA256SUMS.txt` with the sha256 of each zip, checkable with `sha256sum -c SHA256SUMS.txt`, and the same hashes appear in the release notes. The two shipped native binaries, `asfetch` and `aswatcher`, are listed there too, and the **Native binaries** workflow now rebuilds *both* from source on a runner (it only did `asfetch` before), printing the rebuilt hashes next to the committed ones and reporting whether they match. See **Verifying a download** in the README.
- **WebUI theme picker**: a new button next to the language button chooses System / Light / Dark. The choice is remembered and applied before the first paint, so a forced theme never flashes the system one.

**Changed**
- **WebUI opens in one shell round trip instead of fourteen.** Everything the first screen needs (version, build line, flags, interval, keybox size, spoof flags) is read by a single root command, and the mirror lookup for the keybox name no longer blocks the toggles — it used to wait up to 8 s on a bad link before anything was interactive. On older phones the page now shows its controls well under a second after the host grants root.
- **WebUI on old WebViews and odd DPIs.** Every tinted background used `color-mix()`, which the WebView shipped with Android 8–11 doesn't understand, so icon tiles, active tabs and pressed rows rendered with no background at all — they are plain `rgba` now. The status dot's pulse is a transform/opacity animation instead of a repainted `box-shadow`, which alone kept slow GPUs busy while the page sat idle. Font boosting is disabled (`text-size-adjust`), the thing that inflated some labels and not others on very high or very low density screens; long labels and big system font scales wrap instead of pushing toggles off-screen; the header keeps clear of the two floating buttons; narrow (≤380 px) and wide (≥720 px) viewports get their own spacing.
- **Advanced note** now says "leave them default" rather than "leave them off" — a flag's default can be on.
- **WebUI opens on its last state instantly.** The host's first root call can take several seconds on old phones (the page painted at ~4 s here, the answer landed at ~10 s), so the screen sat on "—" with every toggle off. The last read is kept in local storage and painted before the shell is asked; the fresh read repaints when it arrives.

**Fixes**
- **Status indicator off → on brought the status back only an hour later.** Turning the toggle off stripped the prefix from the description (intended), but turning it on merely waited for the next hourly / Action run, so the pill stayed missing and it looked as if the toggle had deleted it. On now fetches and stamps the status right away and reports if there is no connection.
- **Advanced → Reset to defaults**: one button (with a confirm) puts every WebUI setting back to the fresh-install state — all toggles, spoof variables, the check interval, custom packages — and re-runs Action, so the fetched fingerprint replaces an imported one. Your keybox and per-app keybox assignments are kept. Also `sh reset_defaults.sh` from a root shell.

**Fixes**
- **Action no longer opens to a black screen on newer Magisk Alpha.** Alpha builds from app 96221b69 on run `action.sh` with the system `mksh` instead of Magisk's busybox ash; the script's ash-only `set +o standalone` line is a fatal error there, so it died on its second statement with nothing on screen. The Action now re-executes itself under the manager's busybox (Magisk / KernelSU / APatch) before doing anything, and tolerates shells that lack the option. Running `sh action.sh` from any root terminal works the same way.
- **Action rows line up again.** The shield, warning, calendar, info and gear icons carry a Unicode variation selector that Magisk's console draws narrower than every other emoji, so those five rows (the title, `2026-06-05`, every warning) sat a few pixels left of the rest. They are now plain-width glyphs (🔒 ❗ 📅 💡 🔧).
- **Action no longer reports "keybox ok" on a fresh install without internet.** The installer seeds the upstream demo keybox so the engine has something to load, and Action only checked that a keybox-looking file existed. It now asks the mirror every tap: offline shows `no internet — keybox not fetched`, online the fetch runs and the result is what the server said (`keybox updated`, `keybox ok` when the file on disk matches the served one, or `keybox fetch failed`).
- **TEESimulator (JingMatrix) build**: a refreshed keybox and target-list changes now reach the engine immediately. Its daemon only watches `/data/adb/teesim`, where our keybox is a symlink into `/data/adb/tricky_store`, so it never saw the hourly / Action keybox refresh and a fresh install could sit without a keybox until the first hourly tick. The keybox fetcher and the target builder now tell the engine to reload (no-op on TEESimulator-RS / TrickyStoreOSS, which watch the directory themselves).
- **Collect logs** now records what the verdict actually depends on: SELinux mode (flagged loudly when permissive — Play Integrity cannot pass in that state), the real verified-boot / bootloader state from the kernel command line (the props are pinned by the module, so they always looked green), build type and tags, `ro.debuggable`, CPU ABI list, first API level, clock sanity, Magisk / KSU / APatch versions, built-in Zygisk, denylist and Zygisk-provider state, every installed module with its state, Google Play Services and Play Store versions, PlayIntegrityFork / Fix logcat lines (proof the spoof reached GMS), whether the engine library is actually mapped inside `keystore2`, SELinux denials around keystore, the fingerprint file the zygisk really reads (hashed against the display copy), security-patch coherence across all sources, keybox shape (cert / key counts, still no contents), the WebUI flag files, the on-disk module logs, and the JingMatrix TEESimulator symlink / config (identity fields redacted). Every network and IPC probe is time-bounded so the button can no longer hang. The misleading `daemon: not running` line is replaced by the engine's real process name.

## v1.0.4

**New**
- **Lite build** (`-nopif`): hardware attestation + auto keybox, no bundled fingerprint spoof — for setups where the bundled PlayIntegrityFork conflicts with Google Play Services. Drives your own PlayIntegrityFork / Fix if you have one.
- **WebUI Advanced tab**: import your own fingerprint (`pif.json` / `pif.prop`), toggle any spoof flag by name, add custom target packages, select all / unselect unnecessary.
- **Zero-touch first boot**: the first boot after install runs the Action by itself, so a fresh install lands `STRONG` without opening the module.
- Upstream releases now auto-publish (PlayIntegrityFork / PlayIntegrityFix / TEESimulator-RS bumps become a release on their own).

**Fixes**
- **Action no longer gets stuck on a black screen.** Every network step is bounded and falls back to the next downloader; limits are progress-based, so slow networks are never cut off. The native fetcher prefers IPv4 and retries over the other address family when a connection stalls.
- Custom ROMs: ROM version no longer shows "unknown", the LineageOS fast-charging toggle is back, and the security patch follows OTAs again (the aggressive hides are opt-in in the Advanced tab).
- Uninstalling a Lite build no longer removes your own PlayIntegrityFork / Fix.
- The system security-patch date follows the attested patch again (as in v1.0.3), so attestation checkers no longer report "OS patch differs". It never moves the date backwards, and a new **Advanced → Spoof security patch** toggle turns it off.

**Upstream**
- PlayIntegrityFork v18, TEESimulator-RS v6.0.1-307.

**Builds**
- Releases ship three zips: `AlwaysStrong-<ver>.zip` (default), `-inject.zip`, `-nopif.zip` (Lite). The TrickyStoreOSS / TEESimulator (JingMatrix) engines are nightly-only — see `docs/ADVANCED.md`.

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
