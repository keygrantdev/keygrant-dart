/// The words of the contract (sections 3, 5, 8, 10 to 13) as Dart enums: each
/// value's [wire] member is the word the contract, the stored state and the
/// server use.
library;

/// What a fingerprint hashes: the operating system's machine id, or the host name.
enum DeviceKind {
  machine('machine'),
  hostname('hostname');

  const DeviceKind(this.wire);
  final String wire;

  static DeviceKind? fromWire(Object? word) => switch (word) {
        'machine' => DeviceKind.machine,
        'hostname' => DeviceKind.hostname,
        _ => null,
      };
}

/// A definitive refusal from the server, as the stored state keeps it.
enum Refusal {
  revoked('revoked'),
  upgrade('upgrade'),
  outdated('outdated'),
  device('device');

  const Refusal(this.wire);
  final String wire;

  static Refusal? fromWire(Object? word) => switch (word) {
        'revoked' => Refusal.revoked,
        'upgrade' => Refusal.upgrade,
        'outdated' => Refusal.outdated,
        'device' => Refusal.device,
        _ => null,
      };

  /// The status reason the refusal gives.
  LicenseReason get reason => switch (this) {
        Refusal.revoked => LicenseReason.revoked,
        Refusal.upgrade => LicenseReason.upgrade,
        Refusal.outdated => LicenseReason.outdated,
        Refusal.device => LicenseReason.device,
      };
}

/// What `status()` says of the licence. `unknown` (reason `storage`): the
/// state could not be read just now: keep running, and ask again shortly.
enum LicenseState {
  licensed('licensed'),
  trial('trial'),
  expired('expired'),
  invalid('invalid'),
  unlicensed('unlicensed'),
  unknown('unknown');

  const LicenseState(this.wire);
  final String wire;
}

/// Why a licence does not license this build. `upgrade`: the build is NEWER
/// than the key covers. `outdated`: OLDER than its lowest version. `device`:
/// activated on another device. `tampered`: the lease is not this licence's at
/// all. `unknown-key`: signed by a key this build does not carry. `storage`:
/// the state could not be read just now. `revoked-file`: the stored offline
/// licence file is one this build lists as revoked.
enum LicenseReason {
  revoked('revoked'),
  upgrade('upgrade'),
  outdated('outdated'),
  offline('offline'),
  tampered('tampered'),
  unknownKey('unknown-key'),
  device('device'),
  trial('trial'),
  storage('storage'),
  revokedFile('revoked-file');

  const LicenseReason(this.wire);
  final String wire;
}

/// Why `activate()` did not activate.
enum LicenseError {
  invalidKey('invalid-key'),
  limit('limit'),
  revoked('revoked'),
  upgrade('upgrade'),

  /// The key is for a later version than this build: update the app.
  outdated('outdated'),
  network('network'),

  /// The server answered a lease that does not verify here (a configuration error).
  invalidLease('invalid-lease'),

  /// A user-locked key's new device: ask for the address the key was sold to.
  userEmailRequired('user-email-required'),

  /// Not the key's address (or longer than any).
  userEmailMismatch('user-email-mismatch'),

  /// A code was just mailed to that address: ask for it.
  userCodeRequired('user-code-required'),

  /// The code is wrong, expired, used or not six digits.
  userCodeInvalid('user-code-invalid'),

  /// Three codes were sent for the key this hour.
  tooManyCodes('too-many-codes'),

  /// Too many wrong addresses or codes for the key this hour.
  tooManyAttempts('too-many-attempts'),

  /// The code could not be sent just now and nothing was activated: try again.
  tryAgain('try-again');

  const LicenseError(this.wire);
  final String wire;
}

/// Why a licence file was not taken (`importLicenseFile`).
enum LicenseFileError {
  malformed('malformed'),
  notALicenseFile('not-a-license-file'),
  badSignature('bad-signature'),
  unknownKey('unknown-key'),
  wrongProduct('wrong-product'),
  revokedFile('revoked-file'),
  upgrade('upgrade'),
  outdated('outdated');

  const LicenseFileError(this.wire);
  final String wire;
}

/// Why a pickup call (section 13) did not do what it asked.
enum PickupError {
  invalidEmail('invalid-email'),
  wrongCode('wrong-code'),
  codeExpired('code-expired'),
  tooManyAttempts('too-many-attempts'),
  pickupDisabled('pickup-disabled'),
  tryAgain('try-again'),
  network('network');

  const PickupError(this.wire);
  final String wire;
}

/// Why `use()` did not spend (12.9).
enum UseError {
  invalidAmount('invalid-amount'),
  noMeter('no-meter'),
  usedUp('used-up'),
  offlineLimit('offline-limit'),
  notLicensed('not-licensed'),
  storage('storage'),
  revoked('revoked'),
  upgrade('upgrade'),
  outdated('outdated'),
  device('device');

  const UseError(this.wire);
  final String wire;
}

/// Why `restoreByEmail()` did not activate a key: a pickup's error, 13.4's
/// `no-key` (`upgrade` and `outdated` when keys were found but none covers this
/// build), or an activation's.
enum RestoreError {
  invalidEmail('invalid-email'),
  wrongCode('wrong-code'),
  codeExpired('code-expired'),
  tooManyAttempts('too-many-attempts'),
  pickupDisabled('pickup-disabled'),
  tryAgain('try-again'),
  network('network'),
  noKey('no-key'),
  invalidKey('invalid-key'),
  limit('limit'),
  revoked('revoked'),
  upgrade('upgrade'),
  outdated('outdated'),
  invalidLease('invalid-lease'),
  userEmailRequired('user-email-required'),
  userEmailMismatch('user-email-mismatch'),
  userCodeRequired('user-code-required'),
  userCodeInvalid('user-code-invalid'),
  tooManyCodes('too-many-codes');

  const RestoreError(this.wire);
  final String wire;

  static RestoreError _of(String wire) => RestoreError.values.firstWhere((e) => e.wire == wire);

  /// The restore error a pickup error is.
  static RestoreError fromPickup(PickupError error) => _of(error.wire);

  /// The restore error an activation error is.
  static RestoreError fromActivation(LicenseError error) => _of(error.wire);
}

/// Where a status comes from when it is not a key's lease or a trial.
enum LicenseSource {
  /// A stored offline licence file.
  file('file');

  const LicenseSource(this.wire);
  final String wire;
}

/// The kinds of licence file: one that carries a key to activate, and one that
/// licenses offline for good.
enum LicenseFileKind {
  key('key'),
  offline('offline');

  const LicenseFileKind(this.wire);
  final String wire;
}
