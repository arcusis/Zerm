# Zerm Release Signing

Why users saw "Zerm is damaged and can't be opened": every public DMG through v2.1.3 was a `make local` Debug build — **ad-hoc signed** (`Signature=adhoc`, no team ID), never notarized. Gatekeeper rejects quarantined ad-hoc apps outright; since macOS 15 there is no right-click-Open bypass. Tracked as Z#1.

## Trusted pipeline (added 2026-07-03)

`make release` → `scripts/release.sh`:

1. Builds **Release** config, arm64, and signs the outer app with `Zerm.local.entitlements`. That entitlement set disables CloudKit because Developer ID signing alone cannot grant the restricted CloudKit/APS entitlements in `Zerm.entitlements`. Release credentials use the macOS Keychain; only `DEBUG` developer builds use the plaintext `UserDefaults` fallback. On first launch, a Release build migrates verified legacy `LocalKeychain_*` values into Keychain and removes the plaintext copy.
2. Signs with `Developer ID Application: Arcusis LTD (F9Z784RA6D)` + hardened runtime + timestamp.
3. Notarizes app and DMG via `notarytool` (keychain profile `zerm-notary`), staples both, verifies with `spctl`.
4. Creates `Zerm_<release-label>_aarch64.dmg` and the separately EdDSA-signed Sparkle enclosure `Zerm-<release-label>-macos.zip`. The release workflow rejects a GitHub Release unless both exact filenames are present and the tagged appcast/project/ZIP identities agree.

The default release label is the project's three-component `MARKETING_VERSION`. An approved three- or four-component GitHub label can be decoupled with `RELEASE_LABEL` and its canonical `RELEASE_TAG=v<release-label>`. This does not alter the app's Apple-facing `CFBundleShortVersionString`; Sparkle upgrade ordering remains the strictly increasing `CURRENT_PROJECT_VERSION` / `sparkle:version`.

To package an Office-built Release app without compiling on the local development Mac, copy the unsigned app outside this repository's `.release-build` directory and invoke the script directly:

```bash
PREBUILT_APP=/path/to/Zerm.app \
  RELEASE_LABEL=A.B.C.D RELEASE_TAG=vA.B.C.D \
  scripts/release.sh
```

The script validates the source and staged copy before signing: bundle identifier `com.arcusis.zerm`, project marketing version, project build number, and an arm64 main executable must all match. A mismatch, unavailable signature/notary credential, missing Sparkle key/signing tool, or missing release notes stops packaging. This path signs a copy and does not launch or locally rebuild Zerm.

## Credentials

- Developer ID certificate: must be available, with its private key, in the signing Mac's Keychain. An unsigned Office verification build is an input to packaging, not a release artifact.
- Notary credentials: keychain profile `zerm-notary` must pass `notarytool history` before the script alters packaging output. The source API key stays outside the public repository; the one-time setup command is in `BUILDING.md`.
- Note: project `DEVELOPMENT_TEAM` is `V6J6A3VWY2`, which does NOT match the Developer ID team `F9Z784RA6D` — the release script overrides the team on the command line; don't "fix" the project setting without checking dev-machine provisioning.
- Sparkle's EdDSA private key must match `SUPublicEDKey` in `Info.plist`. Its presence on the signing Mac must be verified for each release; the pipeline fails closed rather than writing an unsigned appcast. Automatic update checks are enabled in `Info.plist` and default on in `UpdaterViewModel`, so the ZIP and appcast are required release outputs.

Related: [[Zerm Known Follow Ups]], [[Zerm Production History]]
