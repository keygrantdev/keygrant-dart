# Changelog

## 0.1.1

- Documentation only, no code change: selling through Paddle, the upgrade link is your own checkout page,
  which reads `client_reference_id` from its address and gives it to Paddle.js as custom data under the
  same name. The README says how.

## 0.1.0

- The first release of the KeyGrant Flutter plugin, for iOS, iPadOS, Android, Windows, macOS and
  Linux: a port of the reference Electron SDK held to the SDK contract and every group of the shared
  conformance vectors.
- `KeyGrantLicense`: `status()`, `refresh()`, `activate()` (with a user-locked key's `email` and
  `code`), `deactivate()`, `startTrial()`, `upgradeUrl()`, `has()` and `require()`, `use()` for
  metered uses, `importLicenseFile()` and `importLicenseFileBytes()` with `removeLicenseFile()`, and
  key pickup: `pickUp()`, `confirmPickUp()` and `restoreByEmail()`, for an App Store build that
  restores a web buyer's licence by email.
- Leases verified offline against the product's key set; trials with an anti-reset start; the
  clock guard; renewals, refusals and their waits; offline licence files; the journal of metered
  uses spent with no answer. `status()`, `refresh()`, `startTrial()`, `has()`, `use()` and the pickup
  calls never throw.
- Fingerprints: the registry API on Windows, IOKit on macOS (through the plugin), the machine-id
  files on Linux; on iOS an install id in the Keychain, on Android `ANDROID_ID`. The iOS Keychain
  also keeps a trial's start.
- Default storage: one JSON file per product in the platform's folder, written atomically.
