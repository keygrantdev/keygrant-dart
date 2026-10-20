# KeyGrant for Flutter

Client-side licensing for Flutter apps on iOS, iPadOS, Android, Windows, macOS and Linux. A port of
the reference Electron SDK (`@keygrant/electron`), held to the same behaviour by the shared
conformance vectors (`conformance/vectors.json`). The full guide is at https://keygrant.dev/docs.

A licence is proven to the app by a signed lease (a JWT, EdDSA over Ed25519) that the app checks
**offline** against the product's public key. The app goes online only to activate, to renew a
lease near or past its end, to tell the server it runs a newer major version, to spend a metered
use or report the uses the device spent while it got no answer, or, at most once a day and in the
background, to report a running trial's launch. Licensing fails in favour of the paying customer:
an outage, no network, a 5xx, a 429, an ambiguous 4xx or an answer the SDK cannot use never takes
away a lease that is still valid. Only an explicit verdict from the server, or the lease's own end,
does.

- Flutter 3.47 or later, built and tested with Flutter 3.47.7. Its Android module is
  Flutter 3.47's (Android Gradle Plugin 9), so an older Flutter cannot build it.
- iOS and iPadOS 15, macOS 12, Android 7 (API 24), Windows 10 and Linux, or later.
- Dependencies: `cryptography` (Ed25519), `crypto` (SHA-256), `http`, `ffi`, `meta`, `path_provider`.

## Install

```sh
flutter pub add keygrant
```

The plugin registers itself: nothing to add to `main()`. An isolate your app starts itself (a
background task) calls `DartPluginRegistrant.ensureInitialized()` before it makes a licence there.

## Quick start

```dart
import 'package:keygrant/keygrant.dart';

/// The product's public keys: the `keys` of
/// `GET https://api.keygrant.dev/v1/products/<product>/pubkey`, fetched when you build and
/// shipped with the app. Public: safe to ship.
final license = KeyGrantLicense(LicenseConfig(
  product: 'sluice',
  apiBaseUrl: 'https://api.keygrant.dev',
  publicJwks: parseJwkSet('{"keys":[{"kty":"OKP","crv":"Ed25519","x":"<the x of your key>"}]}'),
  major: 3, // the app's major version: set it, the server checks keys by it
));

Future<void> launch() async {
  final status = await license.status(); // offline-first, usually instant
  switch (status.state) {
    case LicenseState.licensed:
    case LicenseState.trial:
    case LicenseState.unknown: // the state could not be read just now: keep running
      showApp();
    case LicenseState.expired:
    case LicenseState.invalid:
    case LicenseState.unlicensed:
      showActivation(status.reason); // say why; offer activate, trial, restore or buy
  }
}
```

Make one `KeyGrantLicense` per app and share it: its calls run one at a time. The constructor throws
a `LicenseConfigError` for a configuration it cannot use (no public key, both `publicJwk` and
`publicJwks`, a key that is not an Ed25519 public JWK), so the first run shows the mistake.

## The API

| Call | Answers |
|---|---|
| `status({bool forceOnline = false})` | `Future<LicenseStatus>`; never throws |
| `refresh()` | `status()` forced online: call it when the customer says they have paid, or on a "Try again" |
| `activate(String key, {String? email, String? code})` | `Activated` or `ActivateFailed(LicenseError)`; throws only when the state cannot be read or saved. `email` and `code` are what a person typed for a user-locked key |
| `startTrial()` | `Future<LicenseStatus>`; never throws |
| `deactivate()` | `DeactivateResult(released)`: releases the seat and drops the local licence (trial evidence kept) |
| `importLicenseFile(String text, {email, code})`, `importLicenseFileBytes(List<int> bytes, {email, code})` | a licence file's content: an offline file is stored and licenses the app with no network; a key file's key is activated as `activate()` would |
| `removeLicenseFile()` | drops the stored offline licence file; a key the device holds keeps working |
| `has(String code)`, `require(String code)` | whether the licence grants an entitlement, offline; `require` throws `MissingEntitlement` |
| `use(String meter, [int n = 1])` | `UseSpent(left, offline)` or `UseRefused(UseError, left)`; never throws |
| `pickUp(String email)` | `PickUpCodeSent` or `PickUpSendFailed`: a code mailed to the address a key was sold to |
| `confirmPickUp(String email, String code)` | `PickUpKeysFound(keys)` or `PickUpKeysFailed`: the address's keys of the product |
| `restoreByEmail(String email, String code)` | `Restored` or `RestoreFailed(RestoreError)`: the code confirmed and the key that fits this build activated |
| `upgradeUrl(String paymentLink)` | the payment link with this device's activation id as `client_reference_id` (never the key), or null with no activation |

Every error is an enum whose `wire` member is the word every KeyGrant SDK uses
(`LicenseError.invalidKey.wire == 'invalid-key'`).

`deactivate()` drops the local licence whatever the server says, and answers `released: true`
only when KeyGrant confirmed the release (a 200), or when this device held no seat. `released:
false` means the seat may still be held: say so rather than tell the customer it is free. A state
copied from another device (its lease held to another machine) is only dropped here, and nothing is
asked. `deactivate()`, `importLicenseFile()` and `removeLicenseFile()` throw `LicenseCallUnfinished`
behind a call on this licence that has not finished, and the storage's error when the state cannot
be saved (the licence is kept then: try again).

### `LicenseConfig`

| Field | Default | |
|---|---|---|
| `product` | | the product slug |
| `apiBaseUrl` | | `https://api.keygrant.dev` |
| `publicJwks` / `publicJwk` | | the product's key set (give one of the two); `parseJwkSet(text)` reads `/pubkey`'s answer, a list of JWKs or one JWK |
| `major` | `1` | the running app's major version; a 0.x build sets `0` and runs as major 1 |
| `deviceName` | null | a label for the device list (cut to 120 UTF-16 units) |
| `deviceHold` | `true` | false on pooled, non-persistent machines: no lease is then held to its device |
| `httpTimeout` | 15 s | how long any one request may take; the SDK holds every request to it itself |
| `revokedLicenseFiles` | `[]` | the ids of licence files this build refuses, matched exactly |
| `adapters` | defaults | `LicenseAdapters(storage:, registry:, clock:, fingerprinter:, http:)`, any null for the default |

### Statuses

| `state` | `reason` | What to show |
|---|---|---|
| `licensed` | | the app. `test`: a test licence; `entitlements`: what it grants; `meters`: what it counts. With `source` `LicenseSource.file`, a stored offline licence file licenses it: show `licensedTo` |
| `trial` | | the app; `trialDaysLeft`, `trialEndsAt` (ms), `entitlements` |
| `expired` | `offline` | the lease ran out and the server could not be reached: "connect to renew" |
| `expired` | `trial` | the trial is over: buy, or restore a purchase |
| `invalid` | `revoked` | the key was revoked or has expired, or this device was released |
| `invalid` | `upgrade` | this build is newer than the key covers: buy an upgrade (`upgradeUrl`) |
| `invalid` | `outdated` | this build is older than the key covers: update the app |
| `invalid` | `device` | the licence was activated on another device: activate again here |
| `invalid` | `tampered` | the stored lease is not this licence's: activate again |
| `invalid` | `unknownKey` | signed by a key this build does not carry: online the server renews it with the key it signs with now; if it stays so, update the app |
| `invalid` | `revokedFile` | the stored offline licence file is one this build lists as revoked |
| `unlicensed` | | nothing held: activate, start a trial or restore |
| `unknown` | `storage` | the state could not be read just now: keep running and ask again shortly; never show the activation screen for it |

`stalled`: an earlier call on this licence has not finished, so the answer comes from what is
stored, with no ask and no write. `LicenseStatus` compares by content.

## Restoring a purchase in an App Store build

A build that may not take a typed key (an App Store build, under Apple's guideline 3.1.1) restores
a web buyer's licence by the address the key was sold to. Turn on the product's Key pickup in the
dashboard, then:

```dart
// 1. The customer types the address they bought with.
final sent = await license.pickUp(email);
if (sent case PickUpSendFailed(:final error, :final retryAfter)) {
  return showError(error, retryAfter); // invalidEmail, tooManyAttempts, pickupDisabled, tryAgain, network
}
// The answer is the same whether or not the address holds a key: say "if that address bought
// a key, a code is on its way".

// 2. They type the six-digit code that came.
final restored = await license.restoreByEmail(email, code);
switch (restored) {
  case Restored():
    await license.status(); // licensed
  case RestoreFailed(:final error):
    showError(error); // wrongCode, codeExpired (ask for a new code), noKey, upgrade, outdated, limit, ...
}
```

`restoreByEmail` activates, on this device, the key of that address that fits this build: the one
this device already holds a seat on (a reinstall takes its seat back), else one with a free seat,
else the first. The key is never shown to the customer or handed to the app. A user-locked key
activates with the address, and a key locked by code with the code the pickup proved. To let the
customer choose among several keys, call `confirmPickUp(email, code)`, show each `PickedKey` by its
`modelName`, and activate the one picked with `activate(picked.key, email: email, code:
picked.activationCode)`. The keys a confirm answered are kept in memory for ten minutes (never
stored), so a restore with the same code right after asks nothing more, and a restore whose
activation got no answer can be retried with the same code.

## Fingerprints: what a device is

A lease activated on one device is held to it, so a state file copied to another does not license
it. The device is read once per run and kept for the process:

- **Windows**: `MachineGuid` under `HKLM\SOFTWARE\Microsoft\Cryptography`, read through the registry
  API in the 64-bit view.
- **macOS**: `IOPlatformUUID`, read through IOKit by the plugin (so a sandboxed Mac App Store build
  reads it too), else from `/usr/sbin/ioreg`.
- **Linux**: `/etc/machine-id`, else `/var/lib/dbus/machine-id`; an id on a filesystem in memory, or
  written at this boot, is none.
- On those three, a machine with no id falls back to its host name, and the host name's
  fingerprint is always offered beside the machine id's, so every KeyGrant SDK on a machine reads
  the same device.
- **iOS and iPadOS**: an install id the plugin keeps in the Keychain (service `dev.keygrant.install`,
  this device only, never synced), seeded from `identifierForVendor` the first time. It survives
  the app being deleted and installed again. A Keychain that cannot be read (a device locked since
  it started) gives no fingerprint that time, never another id.
- **Android**: `Settings.Secure.ANDROID_ID`, which survives a reinstall and changes with a factory
  reset. A device with none (or the one value some old builds share) gets an install id of the
  SDK's own in the app's private storage, and its seats are never held to the device.
- A phone has no host name worth the name, so on iOS and Android there is no host-name fallback or
  alternate. A read that fails or is slow gives no fingerprint this time, and a lease is then not
  judged by its device: the customer keeps running.

A trial's start is also kept in the iOS Keychain (service `dev.keygrant.trial`), so deleting the app
does not restart a trial. Android keeps no such thing past the app.

Backups: Android's Auto Backup (on by default) and an iOS backup restore the app's files, the KeyGrant
state file among them. Restored onto the same device, nothing changes. Restored onto a new one, the lease
is held to the old device and reads `invalid` / `device` until the customer activates again
(`restoreByEmail` in an App Store build). To skip that, leave `KeyGrant/` out of the app's backup (Android's
`dataExtractionRules` / `fullBackupContent`, iOS's `isExcludedFromBackup`).

## Entitlements and metered uses

```dart
if (await license.has('export-4k')) enable4k();      // a flag on, a number not 0, a text not empty
await license.require('cloud');                        // throws MissingEntitlement('cloud') when not granted

final spent = await license.use('exports');            // before the work it counts
switch (spent) {
  case UseSpent(:final left, :final offline):
    doExport(); // `left` net of this device's unsynced spends; `offline` when it came from the allowance
  case UseRefused(:final error, :final left):
    explain(error, left); // usedUp, offlineLimit, noMeter, notLicensed, storage, ...
}
```

`has` and `require` read the stored licence offline, as `status()` judges it, with no ask and no
write. `use` is exact online; with no answer it spends from the device's offline allowance for the
meter and reports the spend with the next request. Two calls are two spends.

## Licence files

`importLicenseFile(text)` (or `importLicenseFileBytes(bytes)`) takes a `.kglicense` file
(`licenseFileExtension`) the customer drops onto the app or opens from its licence screen, verified
offline. An offline licence file is stored and licenses the app for good with no network; a key
file's key is activated as a typed key is. List a leaked file's id in `revokedLicenseFiles` in an
update to stop it.

## Storage

The state is one JSON file per product, written atomically (a temp file, flushed, renamed):

- Windows: `%LOCALAPPDATA%\KeyGrant\<product>.json`
- macOS: `~/Library/Application Support/KeyGrant/<product>.json` (inside the app's container when sandboxed)
- Linux: `$XDG_CONFIG_HOME/keygrant/<product>.json`, else `~/.config/keygrant/<product>.json`
- iOS and Android: the app's support directory (`getApplicationSupportDirectory()`) + `KeyGrant/<product>.json`

The file is portable between KeyGrant SDKs. Give `LicenseAdapters(storage: ...)` to keep it elsewhere.

## License

MIT
