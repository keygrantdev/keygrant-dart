/// What the licence's calls answer (the SDK contract, section 8): sealed
/// classes, so an app switches over every case.
library;

import 'pickup.dart';
import 'status.dart';
import 'types.dart';

/// What `activate()` did.
sealed class ActivateResult {
  const ActivateResult();
  bool get ok => this is Activated;
}

/// The key is activated on this device.
final class Activated extends ActivateResult {
  const Activated();
}

/// The key was not activated, and why.
final class ActivateFailed extends ActivateResult {
  const ActivateFailed(this.error);
  final LicenseError error;
}

/// What `deactivate()` did about the seat. The local licence is dropped either
/// way; [released] says whether the device's seat is free: true when KeyGrant
/// confirmed the release (a 200), or when this device held no seat to release;
/// false when it could not be asked, or answered anything else.
final class DeactivateResult {
  const DeactivateResult({required this.released});
  final bool released;
}

/// What `importLicenseFile()` did.
sealed class ImportLicenseFileResult {
  const ImportLicenseFileResult();
  bool get ok => this is LicenseFileImported;
}

/// An offline file is stored and licenses the app from now on; a key file's
/// key is activated. [licensedTo] is who the file names.
final class LicenseFileImported extends ImportLicenseFileResult {
  const LicenseFileImported(this.kind, this.licensedTo);
  final LicenseFileKind kind;
  final LicensedTo licensedTo;
}

/// The file was not taken, and why; nothing was stored.
final class LicenseFileRefused extends ImportLicenseFileResult {
  const LicenseFileRefused(this.error);
  final LicenseFileError error;
}

/// A key file whose key's activation failed, as `activate()` answers it.
final class LicenseFileActivationFailed extends ImportLicenseFileResult {
  const LicenseFileActivationFailed(this.error);
  final LicenseError error;
}

/// What `use(meter, n)` did.
sealed class UseResult {
  const UseResult();
  bool get ok => this is UseSpent;
}

/// Spent. [left] is what is left of the meter now, net of this device's
/// unsynced spends; [offline] is true when KeyGrant could not be asked and the
/// spend came from the offline allowance.
final class UseSpent extends UseResult {
  const UseSpent(this.left, {this.offline = false});
  final int left;
  final bool offline;
}

/// Not spent, and why; [left] for `used-up` and `offline-limit`.
final class UseRefused extends UseResult {
  const UseRefused(this.error, [this.left]);
  final UseError error;
  final int? left;
}

/// What `pickUp(email)` did.
sealed class PickUpSendResult {
  const PickUpSendResult();
  bool get ok => this is PickUpCodeSent;
}

/// The code is on its way when the address holds a key of the product; the
/// answer is the same when it does not.
final class PickUpCodeSent extends PickUpSendResult {
  const PickUpCodeSent();
}

/// The ask was refused; [retryAfter] (seconds) when the server says how long to wait.
final class PickUpSendFailed extends PickUpSendResult {
  const PickUpSendFailed(this.error, [this.retryAfter]);
  final PickupError error;
  final int? retryAfter;
}

/// What `confirmPickUp(email, code)` did.
sealed class PickUpKeysResult {
  const PickUpKeysResult();
  bool get ok => this is PickUpKeysFound;
}

/// The address's live keys of the product, for the customer to pick one by
/// its model (never shown as a key).
final class PickUpKeysFound extends PickUpKeysResult {
  const PickUpKeysFound(this.keys);
  final List<PickedKey> keys;
}

/// The confirm was refused; [retryAfter] (seconds) when the server says.
final class PickUpKeysFailed extends PickUpKeysResult {
  const PickUpKeysFailed(this.error, [this.retryAfter]);
  final PickupError error;
  final int? retryAfter;
}

/// What `restoreByEmail(email, code)` did.
sealed class RestoreResult {
  const RestoreResult();
  bool get ok => this is Restored;
}

/// A key of the address is activated on this device.
final class Restored extends RestoreResult {
  const Restored();
}

/// Nothing was activated, and why; [retryAfter] (seconds) when a pickup refusal says.
final class RestoreFailed extends RestoreResult {
  const RestoreFailed(this.error, [this.retryAfter]);
  final RestoreError error;
  final int? retryAfter;
}

/// What `deactivate()`, `importLicenseFile()` and `removeLicenseFile()` throw
/// behind a call on this licence that has not finished: the customer's own
/// action, which the app asks them to try again.
final class LicenseCallUnfinished implements Exception {
  const LicenseCallUnfinished();
  @override
  String toString() => 'LicenseCallUnfinished: a previous licence call has not finished; try again';
}
