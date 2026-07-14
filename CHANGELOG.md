# AlwaysStrong changelog

## v1.0.2

New keybox mirror, a far more reliable fetcher, a custom-keybox file picker in the WebUI, and a faster, steadier Action.

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
