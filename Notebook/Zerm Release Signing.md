# Zerm Release Signing

Why users saw "Zerm is damaged and can't be opened": every public DMG through v2.1.3 was a `make local` Debug build — **ad-hoc signed** (`Signature=adhoc`, no team ID), never notarized. Gatekeeper rejects quarantined ad-hoc apps outright; since macOS 15 there is no right-click-Open bypass. Tracked as Z#1.

## Trusted pipeline (added 2026-07-03)

`make release` → `scripts/release.sh`:

1. Builds **Release** config, arm64, with the `LOCAL_BUILD` flag and `Zerm.local.entitlements` — keeps runtime behavior identical to all previously shipped builds (CloudKit off, UserDefaults key store). The full `Zerm.entitlements` (CloudKit/aps/keychain-groups) are *restricted* entitlements that need a provisioning profile Developer ID signing alone cannot supply — the app would be killed at launch.
2. Signs with `Developer ID Application: Arcusis LTD (F9Z784RA6D)` + hardened runtime + timestamp.
3. Notarizes app and DMG via `notarytool` (keychain profile `zerm-notary`), staples both, verifies with `spctl`.

## Credentials

- Developer ID cert: in login keychain on the release Mac.
- Notary API key: `~/.appstoreconnect/private_keys/AuthKey_<KEY-ID>.p8` (real key ID kept out of the public repo — it's in the local keychain profile `zerm-notary`); the **issuer UUID** must be fetched from App Store Connect → Users and Access → Integrations, then stored once with `xcrun notarytool store-credentials zerm-notary ...` (exact command in `BUILDING.md`).
- Note: project `DEVELOPMENT_TEAM` is `V6J6A3VWY2`, which does NOT match the Developer ID team `F9Z784RA6D` — the release script overrides the team on the command line; don't "fix" the project setting without checking dev-machine provisioning.
- Sparkle EdDSA private key still missing (auto-update signing) — separate issue; `SUEnableAutomaticChecks=false` so releases work without it.

Related: [[Zerm Known Follow Ups]], [[Zerm Production History]]
