# AlwaysStrong changelog

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
